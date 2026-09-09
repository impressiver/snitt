import Foundation
import os
import SnittAutomation
import SnittCapture
import SnittDocument
import SnittExport

/// Bridges automation requests to the same recording machinery the hotkey uses.
///
/// Requests arrive off the main actor; anything touching the coordinator or the
/// status item hops to it. Agent recordings go through the SAME coordinator as
/// hotkey presses, so M2a's transition guard and kill switch apply to them
/// without a second implementation (§5.3).
///
/// The menu-bar INDICATOR is not free that way: it is driven by whoever calls
/// the coordinator, and the hotkey handler in `AppDelegate` is the only such
/// caller that updates it. So this host pushes recording state through
/// `onRecordingState` on every agent start and stop, which `AppDelegate` wires
/// to the same `StatusItemController.update(_:)` the hotkey uses. Without it an
/// agent recording runs with the menu bar showing idle, and §5.3's kill switch
/// is a control nobody has a reason to click.
/// Where the agent-session audit log lives on disk in production.
///
/// Named once so the two sides that must agree on it — `AutomationHost`,
/// which appends to it below, and whatever wires
/// `DiagnosticsBundle.write(auditLogURL:)` into production (neither Task 4
/// nor this task owns that wiring) — can never drift onto two different
/// files. Get this wrong and diagnostics reads an empty log while sessions
/// are audited elsewhere: the M4a `AudioTrackOrder` shape, applied here.
///
/// Application Support, beside `SocketPath`'s socket and `TargetStore`'s
/// cache, for the same reason those two use it: per-user and not writable
/// by another account on a shared machine.
enum AuditLogLocation {
    static func url() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Snitt", isDirectory: true)
        try? FileManager.default.createDirectory(at: base,
                                                 withIntermediateDirectories: true)
        return base.appendingPathComponent("audit.jsonl")
    }
}

final class AutomationHost: AutomationHandling, @unchecked Sendable {
    /// Pushes recording state at the menu bar. `@MainActor` because that is
    /// where `StatusItemController` lives; deliberately not `@Sendable`, so it
    /// can capture the main-actor-isolated app delegate directly.
    typealias RecordingStateSink = @MainActor (RecordingState) -> Void

    /// Resolves git context for a client's working directory.
    ///
    /// Injectable because the production call — `GitContextResolver.resolve` —
    /// was reachable by no test at all: deleting the line outright left the
    /// whole suite green, while it is the line the milestone's headline claim
    /// ("a demo arrives as feature-branch-a1b2c3d.snitt") depends on.
    typealias GitResolving = @Sendable (URL) -> GitContext?

    /// Schedules the watchdog's delayed firing.
    ///
    /// Injectable so tests can control exactly when — or whether — a
    /// watchdog fires instead of racing real wall-clock time. The default
    /// production implementation is a real timer; the two tests that assert
    /// something did NOT happen by the time the watchdog fires
    /// (`watchdogDoesNotStopSomeoneElsesRecording`,
    /// `expiryWhileBusyPreservesTheSession`) used to arm a real 0.2s sleep
    /// and race their own setup against it, which is fine in isolation but
    /// flaked under full-suite parallel load: when the test's own subsequent
    /// `await`s (through the registry and coordinator actors) were delayed
    /// past 200ms by scheduler contention, the timer fired before the test
    /// had finished setting up the very state it meant to test against
    /// (`coordinator.humanStops()`/`clearAgentSession()`, or
    /// `setStopOverride(.busy)`). `fire` is the actual expiry logic
    /// (`expire(sessionID)`); the returned `Task` is what
    /// `cancelWatchdog()`/`setWatchdog()` cancel to abort it.
    typealias WatchdogScheduling = @Sendable (_ seconds: Double,
                                              _ fire: @escaping @Sendable () async -> Void) -> Task<Void, Never>

    private static let realWatchdogScheduling: WatchdogScheduling = { seconds, fire in
        Task.detached {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await fire()
        }
    }

    private let coordinator: any AgentRecordingControlling
    private let settings: @Sendable () -> AgentSettings
    private let resolveGit: GitResolving
    private let onRecordingState: RecordingStateSink
    private let registry = SessionRegistry()
    private var server: AutomationServer?

    /// Where §12's audit trail is written. Injectable so tests write to a
    /// scratch file rather than a real machine's Application Support
    /// directory; production leaves it at its default, `AuditLogLocation.url()`.
    private let auditLogURL: URL

    /// §12's crash-reporting opt-in and the directory it reads from, both
    /// forwarded verbatim to `DiagnosticsBundle.write`. Injectable for the
    /// same reason `auditLogURL` is: a test that never overrides them would
    /// otherwise fall through to `CrashReportSettings.load()` (the real
    /// `UserDefaults.standard`) and `CrashReportCollector.defaultDirectory()`
    /// (the real `~/Library/Logs/DiagnosticReports/`) — isolation that holds
    /// only because of ambient machine state, not because of injection.
    private let crashReportSettings: @Sendable () -> CrashReportSettings
    private let crashReportsDirectory: URL

    /// Per-session (target, startedAt) the audit trail needs at stop time,
    /// keyed by session id.
    ///
    /// Not sourced from `SessionRegistry`: it tracks only the cap and the id,
    /// never the target name the coordinator resolved. A second, purpose-built
    /// store is smaller than widening the registry's contract for one caller.
    private let auditSessions = AuditSessions()

    private static let log = SnittLog.logger(.automation, target: "SnittApp")

    /// §12's three shapes an agent session can end in. Recording only "ended"
    /// makes a cap-terminated session indistinguishable from a clean stop —
    /// exactly the fact an incident review most needs (§5.3).
    private enum AuditOutcome {
        static let completed = "completed"
        static let capped = "capped"
        static let failed = "failed"
        /// A person ended an agent's recording from the menu bar (§5.3's
        /// kill switch). Distinct from `completed` on purpose: an incident
        /// review needs to see that a human intervened, not that the agent
        /// finished normally.
        static let stoppedByHuman = "stoppedByHuman"
    }

    /// The clock the registry's expiry checks are measured against.
    ///
    /// Injectable for the same reason `watchdogScheduling` is: a test that
    /// wants to fire a watchdog deterministically must also be able to make
    /// `SessionRegistry.expiredSession(now:)` see the cap as exceeded
    /// without waiting on real wall-clock time.
    private let now: @Sendable () -> Date
    private let watchdogScheduling: WatchdogScheduling

    /// Guards `watchdog` only. Requests can arrive on several connections at
    /// once, so the task handle needs a lock even though everything else this
    /// class touches is an actor.
    private let lock = NSLock()
    private var watchdog: Task<Void, Never>?

    init(coordinator: any AgentRecordingControlling,
         settings: @escaping @Sendable () -> AgentSettings,
         onRecordingState: @escaping RecordingStateSink = { _ in },
         resolveGit: @escaping GitResolving = { GitContextResolver.resolve(in: $0) },
         now: @escaping @Sendable () -> Date = Date.init,
         watchdogScheduling: @escaping WatchdogScheduling = AutomationHost.realWatchdogScheduling,
         auditLogURL: URL = AuditLogLocation.url(),
         crashReportSettings: @escaping @Sendable () -> CrashReportSettings = { CrashReportSettings.load() },
         crashReportsDirectory: URL = CrashReportCollector.defaultDirectory()) {
        self.coordinator = coordinator
        self.settings = settings
        self.onRecordingState = onRecordingState
        self.resolveGit = resolveGit
        self.now = now
        self.watchdogScheduling = watchdogScheduling
        self.auditLogURL = auditLogURL
        self.crashReportSettings = crashReportSettings
        self.crashReportsDirectory = crashReportsDirectory
    }

    private func pushState(_ state: RecordingState) async {
        let sink = onRecordingState
        await MainActor.run { sink(state) }
    }

    /// Appends `record`, never letting the append fail the recording it
    /// describes: a session that recorded successfully but could not be
    /// audited must still succeed. §12 wants the trail; it is not permitted
    /// to become a new way for a recording to fail.
    private func appendAudit(_ record: AuditRecord) {
        do {
            try AuditLog.append(record, to: auditLogURL)
        } catch {
            // NOT `String(describing: error)`: a Cocoa NSError renders its
            // userInfo, which carries NSFilePath and NSURL — the FULL
            // ABSOLUTE PATH, including the machine's username. In production
            // `auditLogURL` is `~/Library/Application Support/Snitt/audit.jsonl`,
            // so any disk-full, sandbox or permission fault would ship the
            // username into a file people attach to public support threads
            // (§5). domain+code is the precise identity a support engineer
            // wants, and localizedDescription names only fixed sidecar files.
            // See the identical reasoning at RecordingCoordinator.swift.
            let ns = error as NSError
            Self.log.error(
                "Could not write an audit record for session \(record.sessionID, privacy: .public): \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes the START half of §12's audit trail. Only ever called from
    /// `start(_:)`'s `.started` arm, which is reachable exclusively through
    /// the automation socket — every session `AutomationHost` opens is
    /// agent-initiated by construction, so no `isAgent` check is needed here
    /// the way `RecordingCoordinator.initiator(isAgent:)` needs one for
    /// bundle metadata, which also covers the hotkey path.
    ///
    /// Since `AuditLog` is append-only JSONL, this is the FIRST of two
    /// records sharing `sessionID` — `recordSessionEnd` appends the second
    /// once the session ends, rather than rewriting this one in place.
    private func recordSessionStart(sessionID: String, target: String) async {
        let startedAt = now()
        await auditSessions.remember(sessionID, target: target, startedAt: startedAt)
        appendAudit(AuditRecord(sessionID: sessionID,
                                target: target,
                                initiator: Initiator.agent.rawValue,
                                startedAt: startedAt))
    }

    /// Writes the END half: a second record, same `sessionID`, with
    /// `endedAt`/`outcome` filled in. A no-op if this session was never
    /// remembered by `recordSessionStart` (there is nothing true to say about
    /// its start), which is also how a human's own recording — which never
    /// passes through `start(_:)` at all — can never produce an audit line.
    private func recordSessionEnd(sessionID: String, outcome: String) async {
        guard let session = await auditSessions.forget(sessionID) else { return }
        appendAudit(AuditRecord(sessionID: sessionID,
                                target: session.target,
                                initiator: Initiator.agent.rawValue,
                                startedAt: session.startedAt,
                                endedAt: now(),
                                outcome: outcome))
    }

    /// Forgets any agent session, without touching the coordinator.
    ///
    /// Called by `AppDelegate` whenever a HUMAN starts or stops a recording. The
    /// coordinator already invalidates the agent's session id on any stop; this
    /// is the registry's half, so `snitt status` stops claiming a recording that
    /// a person ended from the menu bar.
    func clearAgentSession() async {
        cancelWatchdog()
        // Record the end BEFORE forgetting the id: an agent session stopped
        // from the menu bar is the human kill switch (§5.3) acting on work
        // nobody was watching, and an audit that shows its start with no end
        // reads as still running. `recordSessionEnd` is a no-op for a session
        // that was never audited, so a human's own recording still writes
        // nothing.
        if let closed = await registry.closeAny() {
            await recordSessionEnd(sessionID: closed, outcome: AuditOutcome.stoppedByHuman)
        }
    }

    private func cancelWatchdog() {
        lock.lock()
        let task = watchdog
        watchdog = nil
        lock.unlock()
        task?.cancel()
    }

    private func setWatchdog(_ task: Task<Void, Never>) {
        lock.lock()
        let previous = watchdog
        watchdog = task
        lock.unlock()
        previous?.cancel()
    }

    func start() {
        let server = AutomationServer(socketURL: SocketPath.url(), handler: self)
        try? server.start()
        self.server = server
    }

    func stop() {
        cancelWatchdog()
        server?.stop()
        server = nil
    }

    func handle(_ body: AutomationRequest.Body) async -> AutomationResponse {
        switch body {
        case .handshake:
            return .handshake(HandshakeInfo(protocolVersion: AutomationProtocol.version,
                                            appVersion: AppVersion.current))

        case .status:
            let pause = await coordinator.pauseStateForAgent()
            return .status(await registry.current(now: now(),
                                                  paused: pause?.paused ?? false,
                                                  pausedSeconds: pause?.pausedSeconds))

        case .listTargets:
            return await listTargets()

        case .startRecording(let options):
            return await start(options)

        case .stopRecording(let sessionID):
            return await stop(sessionID)

        case .mark(let sessionID, let label):
            return await mark(sessionID: sessionID, label: label)

        case .pauseRecording(let sessionID):
            return await setPaused(sessionID: sessionID, paused: true)

        case .resumeRecording(let sessionID):
            return await setPaused(sessionID: sessionID, paused: false)

        case .screenshot(let sessionID, let label):
            return await screenshot(sessionID: sessionID, label: label)

        case .reportInput(let sessionID, let kind, let x, let y, let label):
            return await reportInput(sessionID: sessionID, kind: kind, x: x, y: y, label: label)

        case .inspect(let path):
            return inspect(bundlePath: path)

        case .trim(let bundlePath, let start, let end, let auto):
            return await trim(bundlePath: bundlePath, start: start, end: end, auto: auto)

        case .crop(let bundlePath, let rect):
            return await crop(bundlePath: bundlePath, rect: rect)

        case .autoDeepTrim(let bundlePath, let criteria):
            return await autoDeepTrim(bundlePath: bundlePath, criteria: criteria)

        case .export(let bundlePath, let format, let outputPath, let scale, let chapters,
                     let subtitles, let maxSizeBytes, let clicks):
            return await export(bundlePath: bundlePath, format: format, outputPath: outputPath,
                                scale: scale, chapters: chapters, subtitles: subtitles,
                                maxSizeBytes: maxSizeBytes, clicks: clicks)

        case .diagnostics(let outputPath):
            return await diagnosticsExport(outputPath: outputPath)
        }
    }

    /// How far back `snitt diagnostics export` reads the log and audit
    /// trail, in minutes.
    ///
    /// Not tunable by the client (`.diagnostics` carries only `outputPath`):
    /// §12's self-review names this value as untuned and expects it to be
    /// wrong until real support threads say otherwise. 24 hours is picked as
    /// long enough to span "it worked yesterday, not today" without making
    /// every bundle enormous on a machine that has been recording all week.
    private static let diagnosticsSinceMinutes = 24 * 60

    /// Assembles and writes §12's support bundle IN THE APP, not the client
    /// (see `AutomationProtocol.version`'s fifth amendment and
    /// `DiagnosticsBundle`'s doc comment): `OSLogStore(scope:
    /// .currentProcessIdentifier)` reads back only the calling process's own
    /// log entries (spike S8), so only the app can assemble a bundle that
    /// contains the app's own logs.
    private func diagnosticsExport(outputPath: String) async -> AutomationResponse {
        let url = URL(fileURLWithPath: outputPath)
        let crashSettings = crashReportSettings()
        let crashDirectory = crashReportsDirectory
        do {
            let report = try await MainActor.run {
                try DiagnosticsBundle.write(to: url, auditLogURL: auditLogURL,
                                           sinceMinutes: Self.diagnosticsSinceMinutes,
                                           crashReportSettings: crashSettings,
                                           crashReportsDirectory: crashDirectory)
            }
            return .diagnosticsWritten(report)
        } catch {
            return .failure(AutomationError(
                code: .internalError,
                message: "Could not write the diagnostics bundle.",
                hint: String(describing: error)))
        }
    }

    /// Mutates only `edit.json` — `capture.mov` is immutable (§7).
    ///
    /// Runs IN THE APP, not the client, for the same reason `inspect` does:
    /// the CLI cannot read the bundle's `meta.json`/`events.json` to compute
    /// cuts, because the default output directory is TCC-gated (§4.9).
    ///
    /// Duration comes from `CompositionBuilder.mediaDuration(of:)` — the
    /// SAME clock `MovieExporter`/`CompositionBuilder` build the exported
    /// file on — never from `RecordingMetadata.durationSeconds`, which is
    /// WALL time (stamped around the capture, always the longer of the two;
    /// see that property's doc comment) and was never equal to the media
    /// clock on a real recording. Reporting `keptSeconds`/`cutSeconds` on
    /// the wall clock while the export lands on the media clock told an
    /// agent a number the exported file did not have — exactly the
    /// confidently-wrong result §8 forbids. If `capture.mov` cannot be read
    /// to answer that question, the trim is refused rather than falling
    /// back to the wall clock: a refusal an agent can act on beats a number
    /// that quietly does not describe the file it will get.
    /// Sets or removes the crop, and reports the resulting PIXEL dimensions.
    ///
    /// Reads the natural size from `capture.mov` so the answer is what the
    /// export will actually be, not a fraction the caller has to convert. An
    /// agent cannot look at the video (§8), and `--max-size` reasons about
    /// dimensions, so returning "0.5 x 0.5" would be an answer it cannot act on.
    ///
    /// Merges into the existing EDL rather than rebuilding it — D60's finding
    /// was that this exact family of CLI writes silently discarded whatever the
    /// GUI had done.
    private func crop(bundlePath: String, rect: CropRect?) async -> AutomationResponse {
        let bundle: SnittBundle
        do {
            bundle = try SnittBundle(opening: URL(fileURLWithPath: bundlePath))
        } catch {
            return .failure(AutomationError(
                code: .targetNotFound,
                message: "Could not read a recording at that path.",
                hint: "Use the path `snitt record stop` printed."))
        }

        do {
            var edl = try Self.readEDL(for: bundle)
            edl.crop = rect
            try edl.write(to: bundle)

            let natural = try await CompositionBuilder.naturalVideoSize(of: bundle)
            let width = Int((natural.width * (rect?.width ?? 1)).rounded())
            let height = Int((natural.height * (rect?.height ?? 1)).rounded())
            return .cropped(CropSummary(crop: rect, pixelWidth: width, pixelHeight: height))
        } catch {
            return .failure(AutomationError(
                code: .internalError,
                message: "Could not write the crop to this recording.",
                hint: String(describing: error)))
        }
    }

    /// D57's automatic trim, over the socket.
    ///
    /// Unlike the editor's version — which reads signals it has already decoded
    /// for the timeline — this has no open document, so it samples the waveform
    /// and the filmstrip itself. That is a real decode of the movie and the
    /// reason this verb is slower than `trim` or `crop`; it is also why the
    /// filmstrip is asked for at a HIGHER rate than the editor's, since nothing
    /// here has to stay responsive while it runs and the resolution is what
    /// bounds the answer.
    private func autoDeepTrim(bundlePath: String,
                              criteria: DeepTrimCriteria) async -> AutomationResponse {
        let bundle: SnittBundle
        do {
            bundle = try SnittBundle(opening: URL(fileURLWithPath: bundlePath))
        } catch {
            return .failure(AutomationError(
                code: .targetNotFound,
                message: "Could not read a recording at that path.",
                hint: "Use the path `snitt record stop` printed."))
        }

        do {
            let duration = try await CompositionBuilder.mediaDuration(of: bundle)
            // Sampling ran to completion here, so an empty result means the
            // movie HAS no audio tracks rather than that they are still
            // loading — the distinction `AudioEvidence` exists for.
            let sampled = try await WaveformSampler.sample(movieAt: bundle.captureURL)
            let audio: AudioEvidence = sampled.isEmpty ? .silentByConstruction : .sampled(sampled)
            let filmstrip = try await FilmstripSampler.sample(
                movieAt: bundle.captureURL,
                // Four per second rather than the editor's few-hundred cap: the
                // detector can only resolve dead air as finely as the picture is
                // sampled, and here there is no scrolling strip to keep light.
                maxFrames: max(120, Int(duration * 4)),
                height: 48)
            let events = (try? EventLog.read(from: bundle).events) ?? []
            let transcript = try? Transcript.read(from: bundle)

            var edl = try Self.readEDL(for: bundle)
            let kept = KeptRanges.compute(duration: duration, cuts: edl.cuts.map(\.range))
            let found = AutoDeepTrim.deadSpans(
                duration: duration, audio: audio,
                frames: FrameActivity.from(filmstrip),
                transcript: transcript, events: events, criteria: criteria)
            // Already-removed material is not proposed again, so re-running is
            // idempotent rather than stacking folds onto footage that is gone.
            let fresh = found.filter { span in
                kept.contains { $0.start < span.end && span.start < $0.end }
            }

            if !fresh.isEmpty {
                edl.cuts.append(contentsOf: fresh.map {
                Cut(range: $0, label: FoldLabel.describe(span: $0, markers: events))
            })
                try edl.write(to: bundle)
            }
            let remaining = KeptRanges.compute(duration: duration, cuts: edl.cuts.map(\.range))
                .reduce(0) { $0 + ($1.end - $1.start) }
            return .autoTrimmed(AutoTrimSummary(
                spans: fresh.count,
                seconds: fresh.reduce(0) { $0 + ($1.end - $1.start) },
                totalCuts: edl.cuts.count,
                remainingSeconds: remaining))
        } catch {
            return .failure(AutomationError(
                code: .internalError,
                message: "Could not trim this recording.",
                hint: String(describing: error)))
        }
    }

    private func trim(bundlePath: String, start: Double?, end: Double?,
                      auto: Bool) async -> AutomationResponse {
        let bundle: SnittBundle
        do {
            bundle = try SnittBundle(opening: URL(fileURLWithPath: bundlePath))
        } catch {
            return .failure(AutomationError(
                code: .targetNotFound,
                message: "Could not read a recording at that path.",
                hint: "Use the path `snitt record stop` printed."))
        }

        let duration: Double
        do {
            duration = try await CompositionBuilder.mediaDuration(of: bundle)
        } catch {
            return .failure(AutomationError(
                code: .internalError,
                message: "Could not determine the recording's duration from capture.mov.",
                hint: "The bundle's capture.mov may be missing or unreadable, so trim "
                    + "cannot compute a duration that will match an export: "
                    + String(describing: error)))
        }

        do {
            let existing = try Self.readEDL(for: bundle)

            // Both branches end in `existing.trimmed(keeping:duration:)`
            // deliberately (D60): auto-trim only ever computes a new
            // head/tail keep range from event timestamps, exactly like a
            // manual trim computes one from typed `--start`/`--end`
            // numbers, so it is NOT a "replace every cut" operation. Writing
            // `EditDecisionList.autoTrimCuts(...)`'s cuts directly here, as
            // this branch did before the fix, silently discarded any
            // interior cut already made in the GUI or an earlier manual
            // trim the moment someone auto-trimmed — the identical D60
            // data-loss bug the manual branch had, one `if` away.
            let keep: TimeRange
            if auto {
                let events = try Self.readEventsForAutoTrim(for: bundle)
                keep = try EditDecisionList.autoTrimRange(events: events, duration: duration)
            } else {
                keep = TimeRange(start: start ?? 0, end: end ?? duration)
            }
            let cuts = existing.trimmed(keeping: keep, duration: duration).cuts

            var updated = existing
            updated.cuts = cuts
            try updated.write(to: bundle)

            // `TrimSummary`/`KeptRanges.compute` predate cut identity and
            // only need the ranges — a CLI caller reads seconds, not ids.
            let cutRanges = cuts.map(\.range)
            let kept = KeptRanges.compute(duration: duration, cuts: cutRanges)
            let keptSeconds = kept.reduce(0) { $0 + ($1.end - $1.start) }
            return .trimmed(TrimSummary(keptSeconds: keptSeconds,
                                        cutSeconds: duration - keptSeconds,
                                        cuts: cutRanges))
        } catch AutoTrimError.noInputEvents {
            return .failure(AutomationError(
                code: .internalError,
                message: "This recording logged no input events, so there is nothing "
                       + "to auto-trim against.",
                hint: "Auto-trim clips dead air around clicks and keystrokes. An "
                    + "agent-driven recording produces none. Use `snitt trim --start "
                    + "<seconds> --end <seconds>` instead, or `snitt inspect` to see "
                    + "the markers you can trim around."))
        } catch {
            // Was `code: .targetNotFound, "Could not read a recording at that
            // path."` for EVERY error here, including a failed
            // `updated.write(to: bundle)` (full disk, read-only bundle) —
            // which has nothing to do with the path and sent an agent to fix
            // the wrong thing. Mirrors `export`'s catch-all below, which
            // already preserves the real error in the hint.
            return .failure(AutomationError(
                code: .internalError,
                message: "The trim could not be completed.",
                hint: String(describing: error)))
        }
    }

    /// Reads a bundle's `edit.json`, treating "no file" and "unreadable
    /// file" as two different outcomes rather than collapsing both into "no
    /// trims" — the same distinction `MovieExporter.readBundleEvents` draws
    /// for `events.json`, and for the same reason (§8, plus one file over):
    /// a corrupt `edit.json` exporting the whole recording as if it had
    /// never been trimmed is the exact "success" that quietly discards real
    /// work, one step removed from `readBundleEvents`'s chapters case. A
    /// missing file is legitimate — a fresh recording nobody has trimmed
    /// yet — and must still export cleanly at the full range.
    ///
    /// Shared by BOTH `export` and `trim`: the whole-branch review named the
    /// export call site specifically, but the collapsing `try? ... ??
    /// .fullRange()` was the SAME line, verbatim, in `trim` too — trim is
    /// arguably the worse instance, since a corrupt EDL there doesn't just
    /// export the wrong range, it WRITES the wrong range back to
    /// `edit.json`, permanently discarding whatever trim the file actually
    /// had. The defect is the pattern, not the one site a reviewer happened
    /// to trip over.
    private static func readEDL(for bundle: SnittBundle) throws -> EditDecisionList {
        guard FileManager.default.fileExists(atPath: bundle.editURL.path) else {
            return .fullRange()
        }
        return try EditDecisionList.read(from: bundle)
    }

    /// Reads a bundle's `events.json` for auto-trim, with the identical
    /// absent-vs-unreadable distinction `readEDL` draws above and
    /// `MovieExporter.readBundleEvents` draws for export: this is the SAME
    /// class of bug the whole-branch review named at the export site (§8),
    /// not a defect specific to `edit.json`. Auto-trim's own `try? ...
    /// ?? []` used to turn a corrupt `events.json` into "zero events",
    /// which `autoTrimCuts` then reports as `AutoTrimError.noInputEvents` —
    /// a plausible-sounding but WRONG refusal ("this recording has no
    /// input") for what is actually "this recording's event log is
    /// damaged and unreadable". A missing file is legitimate (no logging,
    /// or nothing recorded yet) and must still auto-trim-refuse honestly
    /// against a genuinely empty log.
    private static func readEventsForAutoTrim(for bundle: SnittBundle) throws -> [LoggedEvent] {
        guard FileManager.default.fileExists(atPath: bundle.eventsURL.path) else {
            return []
        }
        return try EventLog.read(from: bundle).events
    }

    /// Reads `capture.mov` and writes the trimmed mp4 (plus, optionally, its
    /// chapters sidecar) IN THE APP, not the client, for the same reason
    /// `trim` does (§4.9): the CLI cannot read `capture.mov` out of the
    /// bundle directory — the default output directory is gated by the
    /// Files-and-Folders TCC service — so it cannot build the composition
    /// itself, only ask the app to.
    private func export(bundlePath: String, format: String, outputPath: String,
                        scale: Double, chapters: Bool, subtitles: Bool,
                        maxSizeBytes: Int?, clicks: Bool) async -> AutomationResponse {
        // Opening the gif seam must not open it to everything else. The CLI
        // and MCP frontends refuse anything else with matching wording
        // (§8) — this must match too, or a client could send a format the
        // frontends already accepted only to have the app refuse it here.
        guard format == "mp4" || format == "gif" else {
            return .failure(AutomationError(
                code: .internalError,
                message: "Unsupported export format \"\(format)\".",
                hint: "Snitt exports mp4 or gif. Omit --format or pass \"mp4\" or \"gif\"."))
        }

        let bundle: SnittBundle
        do {
            bundle = try SnittBundle(opening: URL(fileURLWithPath: bundlePath))
        } catch {
            return .failure(AutomationError(
                code: .targetNotFound,
                message: "Could not read a recording at that path.",
                hint: "Use the path `snitt record stop` printed."))
        }

        let edl: EditDecisionList
        do {
            edl = try Self.readEDL(for: bundle)
        } catch {
            return .failure(AutomationError(
                code: .internalError,
                message: "Could not read this recording's edit.json.",
                hint: "The file exists but is not valid — exporting the whole "
                    + "recording without applying it would silently discard trims "
                    + "the recording actually has: \(String(describing: error))"))
        }
        let outputURL = URL(fileURLWithPath: outputPath)
        // Beside the output, not beside the bundle: an agent that asked for
        // `~/exports/demo.mp4` expects `~/exports/demo.vtt`, not a sidecar
        // buried back in the bundle it trimmed from.
        let chaptersURL = chapters
            ? outputURL.deletingPathExtension().appendingPathExtension("vtt")
            : nil
        // `.subtitles.vtt`, not `.vtt`: both can be requested at once, and a
        // shared name would have one silently overwrite the other — a caption
        // track replaced by a chapter list, discovered only on playback.
        let subtitlesURL = subtitles
            ? outputURL.deletingPathExtension().appendingPathExtension("subtitles.vtt")
            : nil

        do {
            let manifest = try await MovieExporter.export(
                bundle: bundle, edl: edl, scale: scale, to: outputURL,
                chaptersURL: chaptersURL, subtitlesURL: subtitlesURL,
                format: format, maxSizeBytes: maxSizeBytes, clicks: clicks)
            return .exported(manifest)
        } catch CompositionError.everythingCut {
            return .failure(AutomationError(
                code: .internalError,
                message: "The current trim removes the entire recording.",
                hint: "Widen the kept range with a `trim` request before exporting — "
                    + "there is nothing left of this recording to write."))
        } catch CompositionError.noVideoTrack {
            return .failure(AutomationError(
                code: .internalError,
                message: "The recording has no video track to export.",
                hint: "This bundle's capture.mov may be corrupt or incomplete."))
        } catch let error as ExportError {
            return .failure(AutomationError(
                code: .internalError,
                message: "The export failed.",
                hint: String(describing: error)))
        } catch {
            return .failure(AutomationError(
                code: .internalError,
                message: "The export failed.",
                hint: String(describing: error)))
        }
    }

    /// Reads the bundle IN THE APP, not the client.
    ///
    /// The CLI cannot assume it can read the app's (user-configurable)
    /// output directory — at the time this was found it defaulted to
    /// `~/Desktop`, gated by the Files-and-Folders TCC service, which is
    /// exactly how M3a's health block silently reported nothing on every
    /// real machine. The app wrote the file and can always read it.
    ///
    /// Deliberately NOT gated by `ConsentPolicy`: reading a bundle the agent
    /// was handed the path to discloses nothing it did not already have, and
    /// gating it would make an agent unable to describe its own recording.
    private func inspect(bundlePath: String) -> AutomationResponse {
        let bundle: SnittBundle
        do {
            bundle = try SnittBundle(opening: URL(fileURLWithPath: bundlePath))
        } catch {
            return .failure(AutomationError(
                code: .targetNotFound,
                message: "Could not read a recording at that path.",
                hint: "Check the path from `snitt record stop`. It must be a "
                    + ".snitt bundle written by this app."))
        }
        // A separate `do` from the bundle-open above (D60, M5f): a bundle
        // that opened fine can still fail HERE — a `schemaVersion` in
        // `events.json` newer than this build understands throws from
        // `EventLog.init(from:)` (`InspectReport.readEvents`). Folding both
        // failures into one generic "check the path" message would tell an
        // agent to look at the wrong thing; this bundle's PATH was fine; its
        // DATA wasn't.
        do {
            return .inspected(try InspectReport.report(for: bundle))
        } catch {
            return .failure(AutomationError(
                code: .internalError,
                message: "Could not build a report for this recording.",
                hint: "One of its sidecar files exists but could not be read — reporting "
                    + "it as empty would hide a real problem: \(String(describing: error))"))
        }
    }

    private func policy() -> ConsentPolicy {
        let current = settings()
        return ConsentPolicy(agentRecordingEnabled: current.agentRecordingEnabled,
                             fullDisplayAllowed: current.fullDisplayAllowed)
    }

    /// Shown when Screen Recording is not (yet) granted to an agent request.
    ///
    /// `CGRequestScreenCaptureAccess()` returns `false` even when the user grants
    /// permission in the dialog it just raised — the grant only takes effect on
    /// the NEXT launch of Snitt (verified on macOS 26.5.2, spike S5). Saying
    /// "permission denied" here would be actively wrong for the person who just
    /// did the right thing: it must read as "grant it and relaunch", not as a
    /// refusal.
    private static let permissionDeniedError = AutomationError(
        code: .permissionDenied,
        message: "Snitt does not have permission to record the screen yet.",
        hint: "Open Snitt, grant Screen Recording permission in System Settings "
            + "when prompted (or manually under Privacy & Security), then relaunch "
            + "Snitt. The grant does not take effect until Snitt is relaunched.")

    private func listTargets() async -> AutomationResponse {
        // Enumeration is gated too: an agent that may not record has no business
        // learning what windows are open.
        if let refusal = policy().evaluate(StartOptions(bundleIdentifier: "probe")) {
            return .failure(refusal)
        }

        // Enumerating `SCShareableContent` returns nothing useful, and never
        // raises the system prompt, unless access has been explicitly ensured
        // first — this project has shipped that exact defect three times.
        // `CachedTargetResolver`/`RecordingCoordinator` do this on the hotkey
        // path; this is the equivalent guarantee for the agent path.
        let granted = await MainActor.run { ScreenRecordingAccess.ensureGranted() }
        guard granted else {
            return .failure(Self.permissionDeniedError)
        }

        do {
            let targets = try await CaptureTarget.headlessAvailable()
            return .targets(targets.map { target in
                let d = target.descriptor
                // The bundle identifier comes from the SCWindow rather than the
                // descriptor, which does not carry one. It has to be here: the
                // CLI's own `--app` flag takes a bundle id, so a listing without
                // one would advertise targets an agent cannot then record.
                var bundleID: String?
                if case .window(let window) = target {
                    bundleID = window.owningApplication?.bundleIdentifier
                }
                return TargetSummary(id: d.id, kind: d.kind, title: d.title,
                                     applicationName: d.applicationName,
                                     bundleIdentifier: bundleID)
            })
        } catch {
            return .failure(AutomationError(
                code: .permissionDenied,
                message: "Snitt could not list what is on screen.",
                hint: "This usually means Screen Recording permission is missing. "
                    + "Open Snitt and grant it, then relaunch Snitt."))
        }
    }

    private func start(_ options: StartOptions) async -> AutomationResponse {
        if let refusal = policy().evaluate(options) { return .failure(refusal) }

        let maxDuration = policy().effectiveMaxDuration(options.maxDurationSeconds)
        let sessionID: String
        do {
            sessionID = try await registry.open(maxDuration: maxDuration, now: now())
        } catch let error as AutomationError {
            return .failure(error)
        } catch {
            return .failure(AutomationError(code: .internalError,
                                            message: "Could not open a session."))
        }

        let reference: TargetReference
        if let bundleID = options.bundleIdentifier {
            reference = .window(bundleIdentifier: bundleID, titleHint: nil,
                                windowID: options.windowID)
        } else if let displayID = options.displayID {
            reference = .display(id: displayID)
        } else {
            try? await registry.close(sessionID)
            return .failure(AutomationError(code: .targetNotFound,
                                            message: "No target was specified."))
        }

        // Resolved here, not in the coordinator: only the CLIENT knows which
        // repository a recording is about (§7). Snitt.app's own cwd is "/".
        let git = options.workingDirectory
            .map { URL(fileURLWithPath: $0) }
            .flatMap { resolveGit($0) }

        // The agent's audio choices, which used to stop at the wire: nothing
        // read `options.microphone`, so `--mic` was a no-op end to end and
        // `health.micRMS` could only ever be nil.
        // Read at record time rather than cached at launch, so toggling the
        // menu item takes effect on the next recording without a relaunch.
        let captureOptions = CaptureOptions(captureMicrophone: options.microphone,
                                            captureSystemAudio: options.systemAudio,
                                            logInputEvents: EventLoggingSettings.load().enabled)

        let outcome = await coordinator.startForAgent(sessionID: sessionID,
                                                      reference: reference,
                                                      git: git,
                                                      options: captureOptions)
        switch outcome {
        case .started(let name, _):
            await pushState(.recording(startedAt: Date()))
            armWatchdog(sessionID: sessionID, after: maxDuration)
            await recordSessionStart(sessionID: sessionID, target: name)
            return .started(sessionID: sessionID, target: name)
        default:
            try? await registry.close(sessionID)
            return .failure(Self.error(for: outcome))
        }
    }

    private func mark(sessionID: String, label: String?) async -> AutomationResponse {
        if let refusal = policy().evaluate(StartOptions(bundleIdentifier: "probe")) {
            return .failure(refusal)
        }
        switch await coordinator.markForAgent(sessionID: sessionID, label: label) {
        case .marked(let offset):
            return .marked(timeSeconds: offset)
        case .notCurrentSession, .notRecording:
            return .failure(AutomationError(
                code: .noSuchSession,
                message: "No recording with that session id.",
                hint: "Markers can only be added to a recording you started. "
                    + "Check `snitt status` for the current session."))
        }
    }

    /// Pause or resume, returning the session's new status so the caller sees
    /// the state it just asked for rather than having to ask again.
    private func setPaused(sessionID: String, paused: Bool) async -> AutomationResponse {
        if let refusal = policy().evaluate(StartOptions(bundleIdentifier: "probe")) {
            return .failure(refusal)
        }
        switch await coordinator.setPausedForAgent(sessionID: sessionID, paused: paused) {
        case .marked:
            let state = await coordinator.pauseStateForAgent()
            return .status(await registry.current(now: now(),
                                                  paused: state?.paused ?? paused,
                                                  pausedSeconds: state?.pausedSeconds))
        case .notCurrentSession, .notRecording:
            return .failure(AutomationError(
                code: .noSuchSession,
                message: "No agent recording with that session id.",
                hint: "Only the session you started can be paused. A recording a "
                    + "person started is theirs to control — check `snitt status`."))
        }
    }

    private func screenshot(sessionID: String, label: String?) async -> AutomationResponse {
        if let refusal = policy().evaluate(StartOptions(bundleIdentifier: "probe")) {
            return .failure(refusal)
        }
        switch await coordinator.screenshotForAgent(sessionID: sessionID, label: label) {
        case .taken(let path, let timeSeconds):
            return .screenshotTaken(path: path, timeSeconds: timeSeconds)
        case .noFrameYet:
            return .failure(AutomationError(
                code: .internalError,
                message: "The recording has not delivered a frame yet.",
                hint: "Wait a moment and try again — this is normal in the first "
                    + "fraction of a second, and the recording itself is fine."))
        case .notCurrentSession, .notRecording:
            return .failure(AutomationError(
                code: .noSuchSession,
                message: "No agent recording with that session id.",
                hint: "Only the session you started can be photographed. A "
                    + "recording a person started is theirs."))
        }
    }

    private func reportInput(sessionID: String, kind: String,
                             x: Double?, y: Double?, label: String?) async -> AutomationResponse {
        if let refusal = policy().evaluate(StartOptions(bundleIdentifier: "probe")) {
            return .failure(refusal)
        }
        // A reported keystroke carries NO TEXT, and that restriction is the
        // whole reason it is allowed at all. The danger this originally
        // excluded is a caller writing typed input into a recording it did not
        // observe — a claim about what a person typed, which §5.6 governs
        // precisely because keystroke CONTENT is the dangerous part. A
        // content-free beat makes no such claim: it says "I typed at this
        // instant", which is exactly the assertion `cursor` was already
        // trusted to make, at the same level of trust and with the same
        // `reported` provenance.
        //
        // It exists because an agent driving a terminal has no other way to
        // mark its work: `autoTrimRange` finds the bookends from input events,
        // and typing produced none.
        guard let eventKind = EventKind(rawValue: kind),
              eventKind == .click || eventKind == .cursor || eventKind == .keystroke
        else {
            return .failure(AutomationError(
                code: .internalError,
                message: "kind must be \"click\", \"cursor\" or \"keystroke\".",
                hint: "Narration belongs on a marker."))
        }
        if eventKind == .keystroke, label != nil {
            return .failure(AutomationError(
                code: .internalError,
                message: "A reported keystroke cannot carry a label.",
                hint: "Report WHEN you typed, not what. Saying what was typed is a "
                    + "claim about content Snitt never saw, which is what \u{00A7}5.6 governs. "
                    + "Use a marker if the moment needs a name."))
        }
        if eventKind != .keystroke, x == nil || y == nil {
            return .failure(AutomationError(
                code: .internalError,
                message: "\(kind) needs x and y as fractions of the window.",
                hint: "Only a keystroke has no position."))
        }
        switch await coordinator.reportInputForAgent(sessionID: sessionID, kind: eventKind,
                                                     x: x, y: y, label: label) {
        case .marked(let offset):
            return .marked(timeSeconds: offset)
        case .notCurrentSession, .notRecording:
            return .failure(AutomationError(
                code: .noSuchSession,
                message: "No agent recording with that session id.",
                hint: "Input can only be reported into the recording you started."))
        }
    }

    /// Maps a coordinator outcome to the agent-facing contract (§10).
    ///
    /// Every non-started outcome used to become `target_not_found`/14 with the
    /// hint "the application may not be running". Two of them were actively
    /// misleading: a missing Screen Recording grant — the ordinary first-run
    /// state — sent an agent chasing a process that was running fine, and a
    /// human's hotkey recording in progress read as a missing window instead of
    /// `already_recording`.
    static func error(for outcome: CoordinatorOutcome) -> AutomationError {
        switch outcome {
        case .failed(_, .permissionDenied):
            return permissionDeniedError
        case .ignored, .failed(_, .alreadyRecording):
            // `.ignored` means a start or stop was already in flight — from the
            // agent's side that is indistinguishable from, and remediated the
            // same way as, a recording already running.
            return AutomationError(
                code: .alreadyRecording,
                message: "A recording is already in progress.",
                hint: "Stop it first with `snitt record stop`, or check `snitt status`. "
                    + "It may have been started by a person from the menu bar.")
        case .failed(let message, .ambiguousTarget):
            // Its own arm for the same reason `targetTooSmall` has one: the
            // generic "the application may not be running" hint is the opposite
            // of the truth, and the remedy is a parameter rather than an action
            // in the world. The message already carries the window ids.
            return AutomationError(
                code: .targetNotFound,
                message: message,
                hint: "Call snitt_list_targets, then pass the windowID of the one you "
                    + "mean. Snitt refuses to choose for you: with several windows open "
                    + "it would otherwise record whichever happened to be largest, and "
                    + "you would not find out until you watched the result.")
        case .failed(let message, .targetTooSmall):
            // Its own arm because the generic hint — "the application may not be
            // running" — is exactly the wrong advice here: the app IS running.
            return AutomationError(
                code: .targetNotFound,
                message: message,
                hint: "Snitt will not record a window smaller than 100×100 on either "
                    + "axis, because a palette or tooltip is never what was meant. "
                    + "Resize the window, or record a display if a person has "
                    + "allowed full-display agent recording.")
        case .failed(_, .targetUnavailable), .cancelled:
            return AutomationError(
                code: .targetNotFound,
                message: "Could not start recording that target.",
                hint: "Check `snitt targets list` — the application may not be running.")
        case .failed(let message, .internalError):
            return AutomationError(code: .internalError,
                                   message: "Could not start recording that target.",
                                   hint: message)
        case .started, .stopped:
            return AutomationError(code: .internalError,
                                   message: "Could not start recording that target.")
        }
    }

    /// §5.3's session cap, enforced rather than merely reported.
    ///
    /// The cap was computed, stored and queryable, and nothing ever acted on it:
    /// `expiredSession(now:)` had no production caller. Snitt is a resident
    /// menu-bar app that never quits on its own, so an agent that crashes after
    /// `record start` left `AVAssetWriter` writing until the disk filled.
    ///
    /// Two independent guards stop this from ever ending someone ELSE's
    /// recording. The task is cancelled on a normal stop, and even if a stale
    /// one runs, `stopForAgent(sessionID:)` refuses unless the coordinator's
    /// active recording is still that exact session.
    private func armWatchdog(sessionID: String, after seconds: Double) {
        setWatchdog(watchdogScheduling(seconds) { [weak self] in
            await self?.expire(sessionID)
        })
    }

    private func expire(_ sessionID: String) async {
        guard await registry.expiredSession(now: now()) == sessionID else { return }
        switch await coordinator.stopForAgent(sessionID: sessionID) {
        case .stopped, .failed:
            // `.failed` still means the recording is OVER: `stopRecording()`
            // clears `active` before `recorder.stop()` can throw, so only
            // finalization failed. Leaving the indicator lit would be worse
            // than the defect this watchdog exists to fix — a person clicks the
            // menu bar to stop what looks like a live recording, `toggle()`
            // sees `active == nil`, and STARTS a new one through the picker.
            try? await registry.close(sessionID)
            await pushState(.idle)
            // `.capped`, not `.completed`: this is the ONLY path that ends a
            // session by force rather than by request, and it is §5's safety
            // mechanism for an orphaned agent — the fact an incident review
            // most needs, not just "ended".
            await recordSessionEnd(sessionID: sessionID, outcome: AuditOutcome.capped)

        case .notCurrentSession:
            // Someone else's recording, or nothing at all. The registry entry
            // is stale; the indicator is not ours to clear.
            try? await registry.close(sessionID)

        case .busy:
            // Nothing stopped, so nothing may be forgotten — the cap must
            // survive a transition that was merely in flight. Matches `stop()`,
            // which preserves the session for the same reason.
            break
        }
    }

    /// Stops the agent's OWN session.
    ///
    /// Order matters: the registry entry is closed only after the coordinator
    /// confirms it stopped that session. The previous order closed the registry
    /// first and then stopped "whatever is recording", which meant this
    /// interleaving handed an agent a path to someone else's recording: agent
    /// starts S, a person stops S with the kill switch, the person starts their
    /// own recording R, the agent calls `record stop S` — and got R's bundle.
    private func stop(_ sessionID: String) async -> AutomationResponse {
        let result = await coordinator.stopForAgent(sessionID: sessionID)
        switch result {
        case .stopped(let url, _, let health):
            cancelWatchdog()
            try? await registry.close(sessionID)
            await pushState(.idle)
            await recordSessionEnd(sessionID: sessionID, outcome: AuditOutcome.completed)
            return .stopped(bundlePath: url.path, health: health)

        case .notCurrentSession:
            // Either the id was never valid, or a person already ended it. Drop
            // the registry entry if it names this session so `snitt status` and
            // the next `record start` agree with reality — but stop nothing.
            cancelWatchdog()
            try? await registry.close(sessionID)
            return .failure(AutomationError(
                code: .noSuchSession,
                message: "No recording with that session id.",
                hint: "It may have been stopped from Snitt's menu bar. "
                    + "Check `snitt status` for the current session."))

        case .busy:
            return .failure(AutomationError(
                code: .internalError,
                message: "Snitt is busy starting or stopping a recording.",
                hint: "Try `snitt record stop` again in a moment."))

        case .failed(let message):
            cancelWatchdog()
            try? await registry.close(sessionID)
            await pushState(.idle)
            await recordSessionEnd(sessionID: sessionID, outcome: AuditOutcome.failed)
            return .failure(AutomationError(code: .internalError,
                                            message: "The recording did not finalize.",
                                            hint: message))
        }
    }
}

extension AutomationHost {
    /// A host wired for tests that exercise `.trim`/`.export` only.
    ///
    /// Neither touches `coordinator` — they read and write a bundle already
    /// on disk, not the live recording machinery — so this factory hands
    /// them a coordinator that does nothing rather than forcing every such
    /// test to build a `FakeCoordinator` it will never call. A test that
    /// mixes trim/export with `.startRecording`/`.stopRecording`/`.mark`
    /// must construct `AutomationHost` directly with a real fake, the way
    /// `AutomationHostTests.swift` already does — `NullCoordinator` refuses
    /// every one of those on purpose, so such a test fails loudly instead of
    /// silently observing a no-op.
    static func forTesting() -> AutomationHost {
        // `NullCoordinator` never returns `.started`, so no audit record is
        // ever written here — but a stray real-disk touch under
        // `~/Library/Application Support` from a test binary is worth
        // avoiding anyway, so this points at a scratch file instead of
        // `AuditLogLocation.url()`'s production default.
        AutomationHost(coordinator: NullCoordinator(),
                      settings: { AgentSettings(agentRecordingEnabled: true,
                                                fullDisplayAllowed: false) },
                      auditLogURL: FileManager.default.temporaryDirectory
                          .appendingPathComponent("snitt-forTesting-audit-\(UUID().uuidString).jsonl"))
    }
}

/// Refuses every call. See `AutomationHost.forTesting()`.
private actor NullCoordinator: AgentRecordingControlling {
    func startForAgent(sessionID: String, reference: TargetReference,
                       git: GitContext?, options: CaptureOptions) async -> CoordinatorOutcome {
        .failed("NullCoordinator does not record — use a real fake for this test.",
               reason: .internalError)
    }

    func stopForAgent(sessionID: String) async -> AgentStopResult {
        .notCurrentSession
    }

    func markForAgent(sessionID: String, label: String?) async -> AgentMarkResult {
        .notRecording
    }

    func setPausedForAgent(sessionID: String, paused: Bool) async -> AgentMarkResult {
        .notRecording
    }

    func pauseStateForAgent() async -> (paused: Bool, pausedSeconds: Double)? { nil }

    func reportInputForAgent(sessionID: String, kind: EventKind, x: Double?, y: Double?,
                             label: String?) async -> AgentMarkResult {
        .notRecording
    }

    func screenshotForAgent(sessionID: String, label: String?) async -> AgentScreenshotResult {
        .notRecording
    }

}

/// Per-session data the audit trail needs at stop time that `SessionRegistry`
/// does not expose: the resolved target name and the exact `startedAt` the
/// start record used, so the end record's `durationSeconds` matches it
/// exactly rather than being computed from a second, slightly later clock
/// read.
private actor AuditSessions {
    private var started: [String: (target: String, startedAt: Date)] = [:]

    func remember(_ id: String, target: String, startedAt: Date) {
        started[id] = (target, startedAt)
    }

    /// Removes and returns the session's data, if any. A miss means either
    /// this session was never started through `AutomationHost` (a human's own
    /// recording never reaches `recordSessionStart` at all) or its end was
    /// already recorded — either way there is nothing true left to append.
    func forget(_ id: String) -> (target: String, startedAt: Date)? {
        started.removeValue(forKey: id)
    }
}
