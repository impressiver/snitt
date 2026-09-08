import Foundation
import os
import CoreMedia
import ScreenCaptureKit
import SnittDocument

public enum RecorderError: Error, Equatable {
    /// `stop()` was called before `start()`.
    case notStarted
    /// `stop()` was called a second time after finalization already ran.
    case alreadyFinished
}

/// Drives a capture into a complete `.snitt` bundle.
///
/// On stop, writes the sidecar files so the bundle is valid the moment
/// recording ends — no separate "save" step exists (spec section 7).
public actor Recorder {
    private let bundle: SnittBundle
    private let session: CaptureSession
    private let sink: AssetWriterSink
    private let initiator: Initiator
    private let git: GitContext?

    private var startedAt: Date?
    private var isFinished = false
    private let eventLog = SessionEventLog()

    private let logInputEvents: Bool
    /// Internal rather than private so tests can observe that a monitor is
    /// created only when asked, and that `stop()` drops it. `logInputEvents`
    /// was previously unreachable from any test at all.
    private(set) var inputEvents: InputEventMonitor?

    // One logger PER CATEGORY, not per file. `Logger`'s category is fixed at
    // construction, while `DiagnosticCategory` names the KIND OF FAULT — so a
    // single cached logger stamps every message in the file with whichever
    // category happened to be chosen, and §12's "error categories are
    // distinguishable" quietly stops being true.
    private static let permissionLog = SnittLog.logger(.permission, target: "SnittCapture")
    private static let captureLog = SnittLog.logger(.capture, target: "SnittCapture")

    /// How the recorder READS the Input Monitoring grant.
    ///
    /// Injectable purely so both branches of the gate are testable: TCC state
    /// is per-machine, so a test that only ran when the grant was absent would
    /// silently do nothing on a developer machine that has granted the test
    /// runner — and that is where this feature's tests were verified by hand.
    ///
    /// Production always uses `InputMonitoringAccess.isGranted`, never
    /// `CGPreflightListenEventAccess` directly: `AccessConformanceTests` flags
    /// any file that preflights a service without also requesting it, and the
    /// request belongs in the app's menu toggle (with its pre-explain), not here.
    private let isInputMonitoringGranted: @Sendable () -> Bool

    /// - Parameter initiator: Deliberately has NO default. A default of
    ///   `.human` is what let every agent recording ship mislabelled: the
    ///   argument was simply never passed, and nothing failed. Provenance is
    ///   the one metadata field whose whole purpose is telling the two apart,
    ///   so an omission must be a compile error rather than a silent lie.
    /// - Parameter git: Also has NO default, for the same reason. Provenance
    ///   and repository context are the same class of field: a caller that
    ///   forgets one produces a recording that is quietly missing the thing
    ///   the milestone exists to add.
    public init(target: ResolvedTarget,
                bundleURL: URL,
                options: CaptureOptions = CaptureOptions(),
                initiator: Initiator,
                git: GitContext?) throws {
        let bundle = try SnittBundle(creatingAt: bundleURL)
        let descriptor = target.descriptor
        let sink = try AssetWriterSink(
            outputURL: bundle.captureURL,
            videoSize: CGSize(width: descriptor.width, height: descriptor.height)
        )
        self.bundle = bundle
        self.sink = sink
        self.initiator = initiator
        self.git = git
        self.logInputEvents = options.logInputEvents
        self.isInputMonitoringGranted = InputMonitoringAccess.isGranted
        self.session = CaptureSession(target: target, sink: sink, options: options)
    }

    private init(bundle: SnittBundle,
                 sink: AssetWriterSink,
                 session: CaptureSession,
                 initiator: Initiator,
                 git: GitContext? = nil,
                 logInputEvents: Bool = false,
                 isInputMonitoringGranted: @escaping @Sendable () -> Bool
                     = InputMonitoringAccess.isGranted) {   // testing seam only
        self.isInputMonitoringGranted = isInputMonitoringGranted
        self.bundle = bundle
        self.sink = sink
        self.session = session
        self.initiator = initiator
        self.git = git
        self.logInputEvents = logInputEvents
    }

    public func start() async throws {
        startedAt = Date()
        try await session.start()
        installInputMonitorIfEnabled()
    }

    /// Installs the input tap, if the recording asked for one and may have one.
    ///
    /// Split out of `start()` so it is reachable from a test: `start()` itself
    /// needs a live `SCStream`, which no test has, so every assertion about
    /// this gate would otherwise be unreachable — the shape that left the whole
    /// feature untested in the first place.
    func installInputMonitorIfEnabled() {
        // Installed only when asked, and only after capture is running, so a
        // failed recording never leaves a tap installed.
        guard logInputEvents else { return }

        // Preflight BEFORE touching CGEvent.tapCreate. Creating a session tap
        // without the grant is precisely what makes macOS raise its TCC dialog,
        // and reaching that here would put an unannounced system prompt on
        // screen DURING a recording — in frame, and on the agent path with no
        // human present to dismiss it. §4.10 requires the pre-explain first,
        // which is the menu toggle's job, not this one's.
        //
        // Routed through `InputMonitoringAccess` rather than
        // `CGPreflightListenEventAccess` directly: `AccessConformanceTests`
        // flags any file that preflights a service without also requesting it,
        // and the request belongs in the app's toggle, not in the recorder.
        guard isInputMonitoringGranted() else {
            Self.permissionLog.error("Input event logging is enabled but Input Monitoring is not granted; recording without it. events.json will contain markers only.")
            return
        }

        // The wall/media clock inputs are captured here, on the actor, so the
        // tap callback can compute an offset without touching actor state.
        // `session` is an immutable `let` and `Sendable`; `started` is a `Date`.
        let started = startedAt
        let session = self.session

        let monitor = InputEventMonitor { [weak self] kind in
            guard let self else { return }
            // The offset is taken HERE, when the key was actually pressed —
            // not inside the Task, whenever the scheduler gets to it. Computing
            // it in the isolated method put the Task's scheduling delay (under
            // the CPU load of a live screen encode, not small) straight into
            // `timeSeconds`. This is the same fire-and-forget defect that was
            // removed from `mark()`, which could be fixed by awaiting; this
            // callback is nonisolated and cannot await, so the timestamp is
            // captured instead. Arrival order is still not guaranteed —
            // `writeSidecars` sorts, so it does not have to be.
            let offset = Recorder.inputOffset(session: session, startedAt: started)
            Task { await self.recordInputEvent(kind, at: offset) }
        }

        guard monitor.start() else {
            // Surfaced as a log line rather than a thrown error or a new
            // metadata field: the recording itself is fine and must not be
            // aborted, and the honest signal the user acts on is the menu
            // toggle, which no longer stays checked after a refused grant.
            Self.captureLog.error("Input event tap failed to install despite the grant reading as present; recording without it.")
            return
        }
        inputEvents = monitor
    }

    /// The offset an input event happened at, computable off the actor.
    ///
    /// Shares `plausibleOffset` with `mark()` rather than duplicating it, so
    /// the media/wall-clock fallback reasoning has exactly one home.
    nonisolated private static func inputOffset(session: CaptureSession,
                                                startedAt: Date?) -> Double {
        let wallClock = startedAt.map { Date().timeIntervalSince($0) }
        return CaptureSession.plausibleOffset(
            media: session.mediaOffsetNow(), wallClock: wallClock) ?? wallClock ?? 0
    }

    /// The metrics gathered during the writer pass (§12.1).
    ///
    /// Read from the recorder rather than re-read from the written bundle: the
    /// CLI is a thin client (§4.9) and cannot assume it can read the app's
    /// output directory — user-configurable, and possibly pointed at a
    /// location gated by the Files-and-Folders TCC service (`~/Desktop`,
    /// the old hardcoded default, being the obvious example).
    public func capturedHealth() -> CaptureHealth { session.health() }

    /// Stops capture, finalizes the movie, and completes the bundle.
    ///
    /// Sidecar files are written even when finalization fails, so the bundle on
    /// disk stays well-formed and recoverable — but the failure is then
    /// rethrown, because a caller must never be handed a bundle that looks
    /// complete while `capture.mov` is truncated or unplayable.
    public func stop() async throws -> SnittBundle {
        guard startedAt != nil else { throw RecorderError.notStarted }
        guard !isFinished else { throw RecorderError.alreadyFinished }

        let stoppedAt = Date()
        isFinished = true

        // Torn down before any finalization step that could throw, so every
        // path out of this function — success or failure — leaves the tap
        // uninstalled. `stop()` is mandatory on the monitor: a dropped
        // reference while a callback is in flight is a use-after-free, and
        // the monitor's own `stop()` is what prevents that.
        inputEvents?.stop()
        inputEvents = nil

        // Swallowed deliberately: on the testing path there is no live stream,
        // and a stream-stop failure does not corrupt the written movie.
        try? await session.stop()

        var finishError: Error?
        do {
            _ = try await sink.finish()
        } catch {
            finishError = error
        }

        let collectedEvents = await eventLog.snapshot()
        try writeSidecars(stoppedAt: stoppedAt, collectedEvents: collectedEvents)

        if let finishError { throw finishError }
        return bundle
    }

    /// Records a marker at the current offset into the recording.
    ///
    /// Deliberately `async` and awaited rather than spawning a detached task:
    /// the common agent sequence is `record mark` immediately followed by
    /// `record stop`, and a fire-and-forget write loses that race silently
    /// while having already told the agent the marker landed.
    ///
    /// Uses the video's own time base, not wall clock: `startedAt` is stamped
    /// before `session.start()` even runs, so it precedes the first frame's
    /// presentation timestamp by however long SCStream takes to come up. A
    /// marker on the wrong clock points a reviewer at the wrong moment
    /// (§4.12).
    ///
    /// Guarded by `CaptureSession.plausibleOffset`: the media offset assumes
    /// SCStream's presentation timestamps are on the host clock, which holds
    /// today but is untestable without a live display. If that assumption is
    /// ever wrong, the failure would otherwise be silent and total — every
    /// marker at "seconds since boot" — so the wall-clock elapsed is always
    /// computed too and used whenever the two disagree by more than the
    /// guard's slack. The same wall-clock value is also what is used when
    /// there is no video time base yet (a mark before the first frame), where
    /// 0 is the honest answer since the recording has no content yet.
    ///
    /// Returns the offset so the caller can report it — an agent that just
    /// marked "ran the tests" wants to know where that fell.
    /// Stops recording without ending the session (M5e, D53).
    ///
    /// The agent case this exists for: deliberation is not worth filming, and
    /// D49 makes Snitt the coordinator rather than the driver, so pausing while
    /// the agent thinks is how a demo avoids minutes of a static screen.
    ///
    /// Drops a marker, so "where did the pause happen" is answerable from the
    /// recording itself rather than only from the agent's own logs. §5.3's
    /// indicator obligation is why `paused` is also reported in status: a
    /// person at the machine must be able to tell a paused recording from a
    /// running one.
    public func pause() async {
        guard !session.isPaused else { return }
        session.pause()
        await eventLog.add(at: await currentOffset(), kind: .marker, label: "Paused")
    }

    /// Resumes a paused recording. Idempotent.
    public func resume() async {
        guard session.isPaused else { return }
        session.resume()
        await eventLog.add(at: await currentOffset(), kind: .marker, label: "Resumed")
    }

    public var isPaused: Bool { session.isPaused }

    /// Seconds spent paused so far — the difference between how long this
    /// session has been alive and how much footage it holds.
    public var pausedSeconds: Double { session.pausedSeconds }

    /// The offset a marker dropped right now would carry. Extracted from
    /// `mark` so pause/resume stamp on exactly the same clock, rather than
    /// growing a second, subtly different implementation of "now".
    private func currentOffset() async -> Double {
        let wallClock = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        return CaptureSession.plausibleOffset(
            media: session.mediaOffsetNow(), wallClock: wallClock) ?? wallClock
    }

    public func mark(label: String?) async -> Double {
        let offset = await currentOffset()
        await eventLog.add(at: offset, kind: .marker, label: label)
        return offset
    }

    /// Records that input happened, at the offset captured when it happened.
    ///
    /// The offset is a parameter, not something this method computes: by the
    /// time this runs, an unbounded scheduling delay has already passed.
    private func recordInputEvent(_ kind: EventKind, at offset: Double) async {
        await eventLog.add(at: offset, kind: kind, label: nil)
    }

    private func writeSidecars(stoppedAt: Date, collectedEvents: [LoggedEvent]) throws {
        let duration = startedAt.map { stoppedAt.timeIntervalSince($0) }
        let metadata = RecordingMetadata(
            createdAt: startedAt ?? stoppedAt,
            initiator: initiator,
            durationSeconds: duration,
            git: git,
            health: session.health()
        )
        try metadata.write(to: bundle)
        // Sorted by time, not left in arrival order. Input events are appended
        // from unstructured Tasks whose completion order is not the order the
        // keys were pressed in, so arrival order can produce a non-monotonic
        // events.json — which every consumer (chapters, --auto-trim) reads as
        // a timeline. Markers and input events share the log, so the combined
        // array is what gets sorted. Ties keep arrival order, so a marker and
        // an event at the same quantised instant land deterministically.
        let ordered = collectedEvents.enumerated().sorted {
            $0.element.timeSeconds == $1.element.timeSeconds
                ? $0.offset < $1.offset
                : $0.element.timeSeconds < $1.element.timeSeconds
        }.map(\.element)
        try EventLog(events: ordered).write(to: bundle)
        try EditDecisionList.fullRange().write(to: bundle)
    }

    // MARK: - Testing seam

    /// - Parameter logInputEvents: Settable, because hardcoding it to `false`
    ///   meant no test in the suite ever exercised the input-logging path
    ///   through `Recorder` at all — not that a monitor is created only when
    ///   asked, not that `stop()` tears one down before the throwing
    ///   finalization steps. The loss mode there is a use-after-free.
    static func forTesting(bundleURL: URL, videoSize: CGSize,
                           initiator: Initiator = .human,
                           logInputEvents: Bool = false,
                           isInputMonitoringGranted: @escaping @Sendable () -> Bool
                               = InputMonitoringAccess.isGranted) throws -> Recorder {
        let bundle = try SnittBundle(creatingAt: bundleURL)
        let sink = try AssetWriterSink(outputURL: bundle.captureURL,
                                       videoSize: videoSize)
        let session = CaptureSession.forTesting(sink: sink)
        return Recorder(bundle: bundle, sink: sink,
                        session: session, initiator: initiator,
                        logInputEvents: logInputEvents,
                        isInputMonitoringGranted: isInputMonitoringGranted)
    }

    func startForTesting() async throws {
        startedAt = Date()
    }

    /// Installs a monitor without going through the grant, so the teardown
    /// ORDER in `stop()` is testable on a machine with no Input Monitoring
    /// grant (which is every CI machine). The monitor is never started, so no
    /// tap exists; only its lifetime is under test.
    func injectMonitorForTesting(_ monitor: InputEventMonitor) {
        inputEvents = monitor
    }

    /// Appends straight to the event log, bypassing the tap — so the ordering
    /// guarantee in `writeSidecars` can be tested without one.
    func recordInputEventForTesting(_ kind: EventKind, at offset: Double) async {
        await recordInputEvent(kind, at: offset)
    }

    /// Feeds a synthetic buffer straight to the session, bypassing SCStream.
    ///
    /// Declared `nonisolated` (and thus callable without `await`) because
    /// `CMSampleBuffer` is not `Sendable`: routing it across the actor
    /// boundary through an isolated method would be a Swift 6 concurrency
    /// error. This is safe because it only touches `session`, an immutable
    /// `let`, so no actor-isolated state is involved.
    nonisolated func feedForTesting(_ buffer: CMSampleBuffer, _ type: SCStreamOutputType) {
        session.handle(buffer, of: type)
    }
}
