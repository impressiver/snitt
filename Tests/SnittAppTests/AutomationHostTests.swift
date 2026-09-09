import Testing
import Foundation
import SnittAutomation
import SnittCapture
import SnittDocument
@testable import SnittApp

/// Tests for the seam that had none.
///
/// `AutomationHost` sits between the automation protocol and the recording
/// machinery, and every test in this repo used to stop at one side or the other
/// of it: `SessionRegistry` and `ConsentPolicy` were tested as pure logic,
/// `RecordingCoordinator` was tested for its transition guard, and nothing
/// exercised the thing that joins them. That is exactly why an agent recording
/// could run with the menu bar showing idle, and why the session cap could be
/// computed, stored and reported without anything ever enforcing it.

/// A stand-in for `RecordingCoordinator`.
///
/// Necessary because a real `.started` outcome requires a real
/// `SCContentFilter`, which ScreenCaptureKit offers no way to construct without
/// live screen enumeration — the same wall the earlier Task 7 work hit. The
/// coordinator's own behaviour (the transition guard, session ownership) is
/// covered in `RecordingCoordinatorTests`; what is under test here is the host.
actor FakeCoordinator: AgentRecordingControlling {
    var startOutcome: CoordinatorOutcome
    /// nil means "behave like a real coordinator": stop only the owned session.
    var stopOverride: AgentStopResult?

    private(set) var activeSession: String?
    private(set) var startCalls: [String] = []
    private(set) var stopCalls: [String] = []
    private(set) var markCalls: [(sessionID: String, label: String?)] = []
    /// What the host actually handed over. Both were accepted and dropped on
    /// the floor before: `git` was ignored outright, so deleting
    /// `GitContextResolver.resolve` from the host kept every test green, and
    /// `options` did not exist — `--mic` was a no-op end to end.
    private(set) var receivedGit: [GitContext?] = []
    private(set) var receivedOptions: [CaptureOptions] = []

    init(startOutcome: CoordinatorOutcome = .started("Window", usedCache: true)) {
        self.startOutcome = startOutcome
    }

    func setStartOutcome(_ outcome: CoordinatorOutcome) { startOutcome = outcome }
    func setStopOverride(_ result: AgentStopResult?) { stopOverride = result }

    /// Models a human pressing the kill switch: the coordinator forgets the
    /// agent session on ANY stop, whoever initiated it.
    func humanStops() { activeSession = nil }

    func startForAgent(sessionID: String,
                       reference: TargetReference,
                       git: GitContext?,
                       options: CaptureOptions) async -> CoordinatorOutcome {
        startCalls.append(sessionID)
        receivedGit.append(git)
        receivedOptions.append(options)
        if case .started = startOutcome { activeSession = sessionID }
        return startOutcome
    }

    func stopForAgent(sessionID: String) async -> AgentStopResult {
        stopCalls.append(sessionID)
        if let stopOverride { return stopOverride }
        guard activeSession == sessionID else { return .notCurrentSession }
        activeSession = nil
        return .stopped(URL(fileURLWithPath: "/tmp/agent-\(sessionID).snitt"), copied: true, health: nil)
    }

    func markForAgent(sessionID: String, label: String?) async -> AgentMarkResult {
        markCalls.append((sessionID, label))
        guard activeSession != nil else { return .notRecording }
        guard activeSession == sessionID else { return .notCurrentSession }
        return .marked(12.5)
    }

    /// Pause/resume calls, so a test can assert the host reached the
    /// coordinator with the right session and direction (M5e, D53).
    private(set) var pauseCalls: [(session: String, paused: Bool)] = []
    private var isPaused = false
    private var pausedSeconds = 0.0

    /// Models a session already paused when the test begins — the crash-recovery
    /// case D53 names, where an agent restarts and asks status.
    func setPausedForTesting(_ paused: Bool, seconds: Double = 0) {
        isPaused = paused
        pausedSeconds = seconds
    }

    func setPausedForAgent(sessionID: String, paused: Bool) async -> AgentMarkResult {
        pauseCalls.append((sessionID, paused))
        guard activeSession != nil else { return .notRecording }
        guard activeSession == sessionID else { return .notCurrentSession }
        isPaused = paused
        return .marked(12.5)
    }

    func pauseStateForAgent() async -> (paused: Bool, pausedSeconds: Double)? {
        guard activeSession != nil else { return nil }
        return (isPaused, pausedSeconds)
    }

    private(set) var screenshotCalls: [(session: String, label: String?)] = []
    /// What the fake pretends a screenshot produced. Settable so a test can
    /// assert the host passes the offset through unchanged rather than
    /// recomputing it — D53's correlation guarantee is that the offset comes
    /// from the FRAME, and a host that stamped its own would break it.
    private var screenshotResult: AgentScreenshotResult = .taken(path: "/tmp/shot.png", timeSeconds: 4.25)

    func setScreenshotResult(_ result: AgentScreenshotResult) { screenshotResult = result }

    private(set) var reportedInput: [(kind: EventKind, x: Double?, y: Double?)] = []

    func reportInputForAgent(sessionID: String, kind: EventKind, x: Double?, y: Double?,
                             label: String?) async -> AgentMarkResult {
        guard activeSession != nil else { return .notRecording }
        guard activeSession == sessionID else { return .notCurrentSession }
        reportedInput.append((kind, x, y))
        return .marked(7.5)
    }

    func screenshotForAgent(sessionID: String, label: String?) async -> AgentScreenshotResult {
        screenshotCalls.append((sessionID, label))
        guard activeSession != nil else { return .notRecording }
        guard activeSession == sessionID else { return .notCurrentSession }
        return screenshotResult
    }
}

/// Records what the menu bar was told, in order.
@MainActor
final class StateRecorder {
    private(set) var states: [RecordingState] = []
    func record(_ state: RecordingState) { states.append(state) }
}

/// A fresh scratch path per call, so tests never touch a real machine's
/// Application Support directory (`AuditLogLocation.url()`'s production
/// default) and never see another test's audit records.
private func scratchAuditLogURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("snitt-test-audit-\(UUID().uuidString).jsonl")
}

@MainActor
private func makeHost(coordinator: FakeCoordinator,
                      recorder: StateRecorder,
                      fullDisplayAllowed: Bool = false,
                      clock: ManualClock? = nil,
                      watchdog: ManualWatchdog? = nil,
                      auditLogURL: URL = scratchAuditLogURL()) -> AutomationHost {
    let now: @Sendable () -> Date
    if let clock {
        now = { clock.now() }
    } else {
        now = { Date() }
    }
    if let watchdog {
        return AutomationHost(
            coordinator: coordinator,
            settings: { AgentSettings(agentRecordingEnabled: true,
                                      fullDisplayAllowed: fullDisplayAllowed) },
            onRecordingState: { state in recorder.record(state) },
            now: now,
            watchdogScheduling: watchdog.scheduling(),
            auditLogURL: auditLogURL,
            crashReportSettings: { CrashReportSettings(enabled: false) },
            crashReportsDirectory: scratchCrashReportsDirectory())
    }
    return AutomationHost(
        coordinator: coordinator,
        settings: { AgentSettings(agentRecordingEnabled: true,
                                  fullDisplayAllowed: fullDisplayAllowed) },
        onRecordingState: { state in recorder.record(state) },
        now: now,
        auditLogURL: auditLogURL,
        // Structural, not ambient: every `makeHost` caller — and therefore
        // every diagnostics-export test in this file — is isolated from the
        // real `UserDefaults.standard` crash-reporting key and the real
        // `~/Library/Logs/DiagnosticReports/` by construction, not because
        // the key happens to be absent on the machine running the suite.
        crashReportSettings: { CrashReportSettings(enabled: false) },
        crashReportsDirectory: scratchCrashReportsDirectory())
}

/// A directory that is never created. `CrashReportCollector.recent(in:)`
/// treats a missing directory the same as an empty one (no crash has ever
/// been written there), so this is enough to guarantee no test in this file
/// can ever read a real `.ips` file even if a future change flipped
/// `crashReportSettings` on by mistake.
private func scratchCrashReportsDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("AutomationHostTests-crashreports-\(UUID().uuidString)", isDirectory: true)
}

/// A deterministic stand-in for `Date()`, so a watchdog test can make
/// `SessionRegistry.expiredSession(now:)` see a session's cap as exceeded
/// without waiting on real wall-clock time.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date()) { self.current = start }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: Double) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// Lets a test decide exactly when an armed watchdog fires, replacing the
/// real timer `AutomationHost` uses in production.
///
/// This is what removes the flake in "A stale watchdog never stops a later
/// human recording" and "A watchdog that finds the coordinator busy keeps
/// the session and its cap": both tests used to arm a real 0.2s timer and
/// race their own setup (`clearAgentSession()`, `setStopOverride(.busy)`)
/// against it, on the assumption that 200ms of wall-clock time was enough
/// for the setup to finish first. Under full-suite parallel load that
/// assumption broke — the test's own `await`s (through actor hops on the
/// registry and the fake coordinator) could take longer than 200ms, so the
/// timer fired first. With `ManualWatchdog`, the watchdog only ever fires
/// when the test calls `fire()`, so the ordering is guaranteed rather than
/// raced, regardless of how loaded the machine is.
///
/// A plain lock-protected class rather than an actor deliberately:
/// `scheduling()` hands back a closure that `armWatchdog` calls SYNCHRONOUSLY
/// (the closure itself is not `async` — only the `Task` it returns is), and
/// `register(_:)` must complete before that call returns, so that by the
/// time `AutomationHost.start()` hands the test back a `.started` response,
/// the watchdog is already armed and ready for `fire()`. An actor's
/// `register` would only be reachable via `await`, which meant dispatching
/// it onto a detached `Task` from a sync context — exactly the kind of
/// unstructured, unordered hop this whole fix exists to remove: the first
/// version of this helper did precisely that, and “A session that outlives
/// its cap is actually stopped” intermittently observed `fire()` running
/// before that detached registration `Task` had (making `fire()` a silent
/// no-op) — the same class of race as the original bug, just relocated into
/// the test helper meant to fix it.
private final class ManualWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingFire: (@Sendable () async -> Void)?
    private var cancelled = false

    func scheduling() -> AutomationHost.WatchdogScheduling {
        { [weak self] _, fire in
            self?.register(fire)
            let watchdog = self
            return Task {
                await withTaskCancellationHandler {
                    // Long enough to never elapse before the test cancels
                    // it (via `clearAgentSession()`/a normal `stop()`) or
                    // the test process exits; `Task.sleep` is
                    // cancellation-aware and returns immediately on cancel.
                    try? await Task.sleep(for: .seconds(3600))
                } onCancel: {
                    watchdog?.markCancelled()
                }
            }
        }
    }

    private func register(_ fire: @escaping @Sendable () async -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return }
        pendingFire = fire
    }

    private func markCancelled() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        pendingFire = nil
    }

    /// Fires the armed watchdog now, deterministically, awaiting the full
    /// effect of expiry (including the coordinator call) before returning.
    /// A no-op if the watchdog was already cancelled, matching the
    /// production guard against a stale timer that already lost the race.
    func fire() async {
        let (action, isCancelled) = takePendingFire()
        guard let action, !isCancelled else { return }
        await action()
    }

    /// Locking, isolated to a synchronous function: this Swift toolchain
    /// refuses to call `NSLock.lock()`/`unlock()` directly inside an `async`
    /// function body, so the critical section lives here instead.
    private func takePendingFire() -> ((@Sendable () async -> Void)?, Bool) {
        lock.lock(); defer { lock.unlock() }
        let action = pendingFire
        pendingFire = nil
        return (action, cancelled)
    }
}

private func startBody(maxDuration: Double? = nil,
                       microphone: Bool = false,
                       systemAudio: Bool = true,
                       workingDirectory: String? = nil) -> AutomationRequest.Body {
    .startRecording(StartOptions(bundleIdentifier: "com.example.App",
                                 microphone: microphone,
                                 systemAudio: systemAudio,
                                 maxDurationSeconds: maxDuration,
                                 workingDirectory: workingDirectory))
}

// MARK: - Critical 1: the indicator

@MainActor
@Test("An agent recording shows in the menu bar for its whole duration")
func agentStartAndStopDriveTheIndicator() async throws {
    // The discriminating check for Critical 1. Pre-fix, `AutomationHost` never
    // touched the status item at all — `statusItem.update(...)` was called from
    // exactly four places, all inside `AppDelegate.handleHotkey()` — so an agent
    // recording ran with the menu bar showing idle and §5.3's kill switch had no
    // visible reason to be clicked. Both expectations below failed then, because
    // `states` was empty.
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let host = makeHost(coordinator: coordinator, recorder: recorder)

    let started = await host.handle(startBody())
    guard case .started(let sessionID, _) = started else {
        Issue.record("expected a started response, got \(started)")
        return
    }

    guard case .recording = recorder.states.first else {
        Issue.record("the menu bar must show recording for an agent session, got \(recorder.states)")
        return
    }

    let stopped = await host.handle(.stopRecording(sessionID: sessionID))
    guard case .stopped = stopped else {
        Issue.record("expected a stopped response, got \(stopped)")
        return
    }
    #expect(recorder.states.last == .idle,
            "the indicator must return to idle when the agent session ends")
}

@MainActor
@Test("Stop reports health from the coordinator, not from the filesystem")
func stopReportsHealthFromCoordinator() async throws {
    // The discriminating check for the health-reporting regression found on a
    // real machine: the CLI's output directory is user-configurable and, at
    // the time this was found, defaulted to `~/Desktop`, gated by the
    // Files-and-Folders TCC service, so reading RecordingMetadata back off
    // disk silently produced no health block at all — no test caught it
    // because every existing test writes bundles to a temp directory it CAN
    // read. Health must instead arrive through the coordinator's response;
    // this asserts the host forwards it rather than dropping it on the floor.
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let host = makeHost(coordinator: coordinator, recorder: recorder)

    let started = await host.handle(startBody())
    guard case .started(let sessionID, _) = started else {
        Issue.record("expected a started response, got \(started)")
        return
    }

    let expectedHealth = CaptureHealth(meanFrameVariance: 42.0, micRMS: 0.1, systemAudioRMS: nil)
    await coordinator.setStopOverride(
        .stopped(URL(fileURLWithPath: "/tmp/agent-\(sessionID).snitt"),
                copied: true, health: expectedHealth))

    let stopped = await host.handle(.stopRecording(sessionID: sessionID))
    guard case .stopped(_, let health) = stopped else {
        Issue.record("expected a stopped response, got \(stopped)")
        return
    }
    #expect(health == expectedHealth,
            "AutomationHost must forward the coordinator's health, not discard it")
}

@MainActor
@Test("A failed agent start leaves the indicator alone")
func failedStartDoesNotLightTheIndicator() async {
    let coordinator = FakeCoordinator(
        startOutcome: .failed("gone", reason: .targetUnavailable))
    let recorder = StateRecorder()
    let host = makeHost(coordinator: coordinator, recorder: recorder)

    _ = await host.handle(startBody())
    #expect(recorder.states.isEmpty,
            "nothing is recording, so nothing may be indicated")
}

// MARK: - Task 5: §12's audit trail

@MainActor
@Test("An agent session is audited from start to stop")
func agentSessionIsAudited() async throws {
    // The discriminating check: nothing wrote to `auditLogURL` before this
    // task, so this failed against the pre-fix host with an empty array —
    // `AuditLog.read` returning `[]` for a log that was never created.
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let auditLogURL = scratchAuditLogURL()
    let host = makeHost(coordinator: coordinator, recorder: recorder, auditLogURL: auditLogURL)

    let started = await host.handle(startBody())
    guard case .started(let sessionID, let target) = started else {
        Issue.record("expected a started response, got \(started)")
        return
    }

    guard case .stopped = await host.handle(.stopRecording(sessionID: sessionID)) else {
        Issue.record("expected a stopped response")
        return
    }

    // The log is append-only JSONL, so a session's start and end are two
    // records sharing one `sessionID` rather than one record rewritten in
    // place — `AuditLog.append` never reads or rewrites existing content.
    let records = try AuditLog.read(from: auditLogURL)
    #expect(records.count == 2,
            "one record at start, a second appended at stop — never a rewrite")
    #expect(records.allSatisfy { $0.sessionID == sessionID })
    #expect(records.allSatisfy { $0.initiator == "agent" })
    #expect(records.allSatisfy { $0.target == target })

    guard let last = records.last else {
        Issue.record("expected a second record")
        return
    }
    #expect(last.endedAt != nil, "the end record must carry when the session ended")
    #expect(last.outcome == "completed")
    #expect(last.durationSeconds != nil && last.durationSeconds! >= 0,
            "an incident review needs how long the session ran")
}

@MainActor
@Test("A human recording writes no audit record")
func humanRecordingIsNotAudited() async throws {
    // §12 scopes the audit to agent-initiated work; auditing every human
    // recording would bury the agent entries the audit exists to surface.
    // `AutomationHost` never sees a human's OWN recording at all — the only
    // entry point a human's activity reaches is `clearAgentSession()`, which
    // `AppDelegate` calls on every human start AND stop, whether or not an
    // agent session was ever open. The discriminating mutation: an
    // implementation that writes an audit line unconditionally inside
    // `clearAgentSession()` (reasoning "this is where sessions end") would
    // fail this, because it fires for a plain human recording too.
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let auditLogURL = scratchAuditLogURL()
    let host = makeHost(coordinator: coordinator, recorder: recorder, auditLogURL: auditLogURL)

    // A person starts, then stops, their own recording — never touching the
    // automation socket at all. `AppDelegate` reports both edges here.
    await host.clearAgentSession()
    await host.clearAgentSession()

    let records = try AuditLog.read(from: auditLogURL)
    #expect(records.isEmpty, "no agent session ever ran, so nothing may be logged")
}

@MainActor
@Test("A capped session records that the cap ended it")
func cappedSessionRecordsTheCap() async throws {
    // The cap is §5's safety mechanism for an orphaned agent session — the
    // single fact an incident review most needs. A bundle recording only
    // "ended" (or any single outcome shared with a clean stop) makes this
    // indistinguishable from `agentSessionIsAudited`'s normal stop, which is
    // exactly the discriminating mutation: collapse `AuditOutcome.capped` to
    // `AuditOutcome.completed` (or any one shared string) and this fails
    // while `agentSessionIsAudited` keeps passing.
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let clock = ManualClock()
    let watchdog = ManualWatchdog()
    let auditLogURL = scratchAuditLogURL()
    let host = makeHost(coordinator: coordinator, recorder: recorder,
                       clock: clock, watchdog: watchdog, auditLogURL: auditLogURL)

    let started = await host.handle(startBody(maxDuration: 0.2))
    guard case .started(let sessionID, _) = started else {
        Issue.record("expected a started response, got \(started)")
        return
    }

    clock.advance(by: 0.3)
    await watchdog.fire()

    let records = try AuditLog.read(from: auditLogURL)
    #expect(records.count == 2)
    guard let last = records.last(where: { $0.sessionID == sessionID && $0.endedAt != nil }) else {
        Issue.record("expected an end record for the capped session, got \(records)")
        return
    }
    #expect(last.outcome == "capped",
            "a cap-terminated session must not read as an ordinary clean stop")
}

// MARK: - Critical 2: the session cap is enforced, not merely reported

@MainActor
@Test("A session that outlives its cap is actually stopped")
func expiredSessionIsStopped() async throws {
    // The discriminating check for Critical 2. `ConsentPolicy.effectiveMaxDuration`
    // clamped the cap, `SessionRegistry.open` stored it and `expiredSession(now:)`
    // reported it — and `expiredSession` had NO production caller, only tests.
    // There was no timer and no watchdog, so an agent that crashed after
    // `record start` left AVAssetWriter writing indefinitely: Snitt is a
    // resident menu-bar app that never quits on its own. Pre-fix this test hung
    // on the poll below until it failed, because nothing ever stopped anything.
    //
    // The watchdog's firing is driven by `ManualWatchdog.fire()` rather than a
    // real timer, and the cap's expiry by `ManualClock` rather than real
    // elapsed time — both deterministic, so this test cannot flake under load
    // the way a real 0.2s race against the suite's own scheduling once did.
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let clock = ManualClock()
    let watchdog = ManualWatchdog()
    let host = makeHost(coordinator: coordinator, recorder: recorder,
                       clock: clock, watchdog: watchdog)

    // A cap below the 600s ceiling passes through `effectiveMaxDuration`
    // unchanged, so this is the real production path and not a test-only knob.
    let started = await host.handle(startBody(maxDuration: 0.2))
    guard case .started(let sessionID, _) = started else {
        Issue.record("expected a started response, got \(started)")
        return
    }

    clock.advance(by: 0.3)
    await watchdog.fire()

    let stopped = await coordinator.stopCalls
    #expect(stopped == [sessionID],
            "the cap exists so a hung agent cannot fill the disk; it must ACT")

    let status = await host.handle(.status)
    #expect(status == .status(StatusInfo(recording: false, sessionID: nil,
                                         elapsedSeconds: nil)),
            "the expired session must be closed, not left claiming to record")
    #expect(recorder.states.last == .idle,
            "the indicator must clear when the watchdog ends the session")
}

@MainActor
@Test("A stale watchdog never stops a later human recording")
func watchdogDoesNotStopSomeoneElsesRecording() async throws {
    // The failure mode this fix must not introduce: a watchdog armed for a
    // session that has since ended firing into whatever is recording now. Two
    // guards must hold — the task is cancelled on a normal stop, and
    // `stopForAgent` refuses a session the coordinator no longer owns.
    //
    // This used to arm a real 0.2s timer, cancel it via `clearAgentSession()`,
    // then sleep 600ms hoping that was long enough to observe "nothing
    // happened". Under full-suite parallel load the test's own await between
    // `started` and `clearAgentSession()` could itself take longer than
    // 200ms, so the real timer sometimes fired and stopped the coordinator
    // BEFORE the cancellation reached it — an intermittent failure that had
    // nothing to do with the property under test. `ManualWatchdog` removes
    // the race entirely: cancellation and firing are both explicit calls, so
    // there is no wall-clock window for the timer to win.
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let clock = ManualClock()
    let watchdog = ManualWatchdog()
    let host = makeHost(coordinator: coordinator, recorder: recorder,
                       clock: clock, watchdog: watchdog)

    let started = await host.handle(startBody(maxDuration: 0.2))
    guard case .started = started else {
        Issue.record("expected a started response, got \(started)")
        return
    }
    // A person stops it from the menu bar, then starts their own recording.
    await coordinator.humanStops()
    await host.clearAgentSession()

    // Even though the cap has (simulated-)elapsed, the watchdog was
    // cancelled above, so firing it now must be a no-op.
    clock.advance(by: 0.3)
    await watchdog.fire()

    let stopCalls = await coordinator.stopCalls
    #expect(stopCalls.isEmpty,
            "a cancelled watchdog must not reach the coordinator at all")
    #expect(!recorder.states.contains(.idle),
            "the watchdog must not blank the indicator over a human's recording")
}

@MainActor
@Test("A watchdog stop that fails to finalize still clears the indicator")
func expiryWithFailedFinalizeClearsTheIndicator() async throws {
    // A regression this fix wave introduced, caught in re-review. `.failed` from
    // `stopForAgent` still means the recording is OVER — `stopRecording()` sets
    // `active = nil` before `recorder.stop()` can throw, so only finalization
    // failed. Gating the idle push on `.stopped` alone left the menu bar lit
    // with nothing running: a person clicks it to stop what looks live,
    // `toggle()` sees `active == nil`, and STARTS a new recording through the
    // picker. Worse than the defect the watchdog exists to fix.
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let clock = ManualClock()
    let watchdog = ManualWatchdog()
    let host = makeHost(coordinator: coordinator, recorder: recorder,
                       clock: clock, watchdog: watchdog)

    let started = await host.handle(startBody(maxDuration: 0.2))
    guard case .started(let sessionID, _) = started else {
        Issue.record("expected a started response, got \(started)")
        return
    }
    await coordinator.setStopOverride(.failed("writer would not finalize"))

    clock.advance(by: 0.3)
    await watchdog.fire()

    #expect(await coordinator.stopCalls == [sessionID])
    #expect(recorder.states.last == .idle,
            "an unfinalized recording is still a STOPPED recording; a lit indicator now means the kill switch starts a new one")

    let status = await host.handle(.status)
    #expect(status == .status(StatusInfo(recording: false, sessionID: nil,
                                         elapsedSeconds: nil)))
}

@MainActor
@Test("A watchdog that finds the coordinator busy keeps the session and its cap")
func expiryWhileBusyPreservesTheSession() async throws {
    // Matches `stop()`, which preserves the session on `.busy` and has a test
    // saying so. Nothing stopped, so nothing may be forgotten — dropping the
    // registry entry here would abandon the cap on a recording still running.
    //
    // This used to arm a real 0.2s timer and race `setStopOverride(.busy)`
    // against it, on the assumption 200ms was enough time to set the override
    // first. Under full-suite parallel load that assumption broke: if the
    // timer fired before `setStopOverride(.busy)` ran, the watchdog stopped
    // against the coordinator's DEFAULT outcome (an ordinary `.stopped`)
    // instead of `.busy`, closing the registry entry the test then expected
    // to still be open — the exact `info.recording → false` failure seen
    // under load. `ManualWatchdog.fire()` is called only after the override
    // is set, so the ordering is guaranteed rather than raced.
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let clock = ManualClock()
    let watchdog = ManualWatchdog()
    let host = makeHost(coordinator: coordinator, recorder: recorder,
                       clock: clock, watchdog: watchdog)

    let started = await host.handle(startBody(maxDuration: 0.2))
    guard case .started(let sessionID, _) = started else {
        Issue.record("expected a started response, got \(started)")
        return
    }
    await coordinator.setStopOverride(.busy)

    clock.advance(by: 0.3)
    await watchdog.fire()

    #expect(await coordinator.stopCalls == [sessionID])

    let status = await host.handle(.status)
    guard case .status(let info) = status else {
        Issue.record("expected status")
        return
    }
    #expect(info.recording && info.sessionID == sessionID,
            "a stop that did not happen must not abandon the cap")
    #expect(!recorder.states.contains(.idle))
}

// MARK: - Important 3: outcomes map to the agent-facing contract

@Test("Each coordinator failure maps to its own error code")
func outcomesMapToCodes() {
    // Pre-fix, every one of these was `target_not_found` / exit 14 with the hint
    // "the application may not be running". The two that matter most: a missing
    // Screen Recording grant is the ordinary first-run state and needs
    // permission_denied with a relaunch hint, and a human's hotkey recording in
    // progress is `already_recording` — a Definition-of-Done item.
    let cases: [(CoordinatorOutcome, AutomationError.Code)] = [
        (.failed("denied", reason: .permissionDenied), .permissionDenied),
        (.failed("busy", reason: .alreadyRecording), .alreadyRecording),
        (.ignored, .alreadyRecording),
        (.failed("gone", reason: .targetUnavailable), .targetNotFound),
        (.cancelled, .targetNotFound),
        (.failed("writer blew up", reason: .internalError), .internalError),
        (.failed("Editor has no window larger than 100×100 to record.",
                 reason: .targetTooSmall), .targetNotFound),
    ]
    for (outcome, expected) in cases {
        #expect(AutomationHost.error(for: outcome).code == expected,
                "\(outcome) must not be collapsed into another code")
    }
}

@Test("A missing screen-recording grant tells the agent to grant and relaunch")
func permissionDeniedCarriesTheRelaunchHint() {
    let error = AutomationHost.error(for: .failed("x", reason: .permissionDenied))
    #expect(error.hint?.contains("relaunch") == true,
            "the grant does not take effect until Snitt is relaunched (spike S5)")
    #expect(AutomationError.exitCode[error.code] == 15)
}

@Test("A too-small window is not reported as an app that may not be running")
func tooSmallCarriesItsOwnAdvice() {
    // Folding this into the generic `targetUnavailable` arm reintroduced exactly
    // what finding 3 removed: an agent told its running app is not running
    // retries or gives up, instead of resizing the window.
    let error = AutomationHost.error(
        for: .failed("Editor has no window larger than 100×100 to record.",
                     reason: .targetTooSmall))
    #expect(error.code == .targetNotFound)
    #expect(error.message.contains("no window larger than"),
            "the agent must be told what is actually wrong")
    #expect(error.hint?.contains("may not be running") != true,
            "the application IS running — that hint is the wrong advice here")
    #expect(error.hint?.contains("Resize") == true)
}

@MainActor
@Test("A human recording in progress is reported as already_recording, not target_not_found")
func humanRecordingIsAlreadyRecording() async {
    let coordinator = FakeCoordinator(
        startOutcome: .failed("A recording is already in progress.",
                              reason: .alreadyRecording))
    let recorder = StateRecorder()
    let host = makeHost(coordinator: coordinator, recorder: recorder)

    let response = await host.handle(startBody())
    guard case .failure(let error) = response else {
        Issue.record("expected a failure, got \(response)")
        return
    }
    #expect(error.code == .alreadyRecording)
    #expect(AutomationError.exitCode[error.code] == 13)
}

@MainActor
@Test("A refused start does not leave a session behind")
func refusedStartClosesTheRegistryEntry() async {
    let coordinator = FakeCoordinator(
        startOutcome: .failed("gone", reason: .targetUnavailable))
    let recorder = StateRecorder()
    let host = makeHost(coordinator: coordinator, recorder: recorder)

    _ = await host.handle(startBody())
    let status = await host.handle(.status)
    #expect(status == .status(StatusInfo(recording: false, sessionID: nil,
                                         elapsedSeconds: nil)))

    // ...and a second attempt is not refused with `already_recording`.
    await coordinator.setStartOutcome(.started("Window", usedCache: true))
    guard case .started = await host.handle(startBody()) else {
        Issue.record("a failed start must not block the next one")
        return
    }
}

// MARK: - Important 4: no cross-ownership leak

@MainActor
@Test("A kill-switch stop means a later record stop cannot claim someone else's bundle")
func killSwitchStopPreventsBundleLeak() async {
    // The interleaving from review: agent starts S; a person clicks the menu-bar
    // kill switch, stopping S; the person starts their own recording R; the
    // agent calls `record stop S`. Pre-fix, `stop` closed the registry entry
    // FIRST and then asked the coordinator to stop "whatever is recording",
    // which stopped R and returned R's filesystem path to the agent.
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let host = makeHost(coordinator: coordinator, recorder: recorder)

    let started = await host.handle(startBody())
    guard case .started(let sessionID, _) = started else {
        Issue.record("expected a started response, got \(started)")
        return
    }

    // The kill switch: `AppDelegate.handleHotkey()` stops via the coordinator
    // and tells the host to forget the session.
    await coordinator.humanStops()
    await host.clearAgentSession()
    // The person now starts their own recording. It is NOT an agent session, so
    // the coordinator owns no session id for it and `stopForAgent` must refuse.

    let response = await host.handle(.stopRecording(sessionID: sessionID))
    guard case .failure(let error) = response else {
        Issue.record("an agent must not be handed a recording it did not start: \(response)")
        return
    }
    #expect(error.code == .noSuchSession)
    #expect(await coordinator.stopCalls == [sessionID],
            "the host may ASK, but the coordinator must refuse — the answer must never be another recording's bundle path")
    #expect(!recorder.states.contains(.idle),
            "the human's live recording must not be un-indicated by the agent's stop")
}

@MainActor
@Test("The registry entry survives a coordinator stop that did not happen")
func busyStopKeepsTheSession() async {
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let host = makeHost(coordinator: coordinator, recorder: recorder)

    let started = await host.handle(startBody())
    guard case .started(let sessionID, _) = started else {
        Issue.record("expected a started response, got \(started)")
        return
    }

    await coordinator.setStopOverride(.busy)
    let response = await host.handle(.stopRecording(sessionID: sessionID))
    guard case .failure(let error) = response else {
        Issue.record("expected a failure, got \(response)")
        return
    }
    #expect(error.code == .internalError)

    // The session is still open, because nothing actually stopped.
    let status = await host.handle(.status)
    guard case .status(let info) = status else {
        Issue.record("expected status")
        return
    }
    #expect(info.recording && info.sessionID == sessionID,
            "a stop that did not happen must not erase the session")
}

// MARK: - Consent still gates everything

@MainActor
@Test("Agent recording that has not been opted into never reaches the coordinator")
func consentGatesTheCoordinator() async {
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let host = AutomationHost(coordinator: coordinator,
                              settings: { AgentSettings(agentRecordingEnabled: false) },
                              onRecordingState: { state in recorder.record(state) },
                              auditLogURL: scratchAuditLogURL())

    let response = await host.handle(startBody())
    guard case .failure(let error) = response else {
        Issue.record("expected a refusal, got \(response)")
        return
    }
    #expect(error.code == .consentRequired)
    #expect(await coordinator.startCalls.isEmpty,
            "a refused request must never reach the recording machinery")
    #expect(recorder.states.isEmpty)
}

// MARK: - The git wiring, which nothing reached

@MainActor
@Test("The client's working directory is resolved and handed to the coordinator")
func workingDirectoryBecomesGitContext() async {
    // The discriminating check. `GitContextResolver.resolve(in:)` had no test
    // reaching it: `FakeCoordinator.startForAgent` accepted `git:` and ignored
    // it, so deleting the resolve call from `AutomationHost` entirely left all
    // 184 tests green — while that one line is what §7's "a demo arrives as
    // feature-branch-a1b2c3d.snitt" depends on.
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let seen = AskedPaths()
    let host = AutomationHost(
        coordinator: coordinator,
        settings: { AgentSettings(agentRecordingEnabled: true) },
        onRecordingState: { state in recorder.record(state) },
        resolveGit: { url in
            seen.record(url.path)
            return GitContext(branch: "feat/markers", commit: "a1b2c3d")
        },
        auditLogURL: scratchAuditLogURL())

    _ = await host.handle(startBody(workingDirectory: "/Users/someone/src/project"))

    #expect(seen.all == ["/Users/someone/src/project"],
            "the CLIENT's cwd is the only one that means anything — Snitt.app's own is \"/\"")
    let git = await coordinator.receivedGit
    #expect(git.count == 1)
    #expect(git.first??.branch == "feat/markers")
    #expect(git.first??.commit == "a1b2c3d",
            "git context that stops at the host never reaches meta.json or the bundle name")
}

@MainActor
@Test("A request with no working directory resolves nothing")
func noWorkingDirectoryMeansNoGit() async {
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let seen = AskedPaths()
    let host = AutomationHost(
        coordinator: coordinator,
        settings: { AgentSettings(agentRecordingEnabled: true) },
        onRecordingState: { state in recorder.record(state) },
        resolveGit: { url in seen.record(url.path); return GitContext(branch: "x") },
        auditLogURL: scratchAuditLogURL())

    _ = await host.handle(startBody())

    #expect(seen.all.isEmpty, "nothing may be guessed from Snitt.app's own cwd")
    let git = await coordinator.receivedGit
    #expect(git.count == 1 && git[0] == nil)
}

/// Thread-safe because the resolver closure is `@Sendable`.
private final class AskedPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func record(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
}

// MARK: - Important 4: --mic reaches the capture

@MainActor
@Test("--mic reaches the capture options instead of stopping at the wire")
func microphoneOptionIsThreadedThrough() async {
    // `StartOptions.microphone` was parsed by the CLI and the MCP bridge and
    // travelled over the socket, and then nothing read it: `RecordingCoordinator`
    // built `Recorder(...)` with no `options:`, so no `.microphone` output was
    // ever added to the stream and `health.micRMS` was always nil.
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let host = makeHost(coordinator: coordinator, recorder: recorder)

    _ = await host.handle(startBody(microphone: true, systemAudio: false))

    let options = await coordinator.receivedOptions
    #expect(options.count == 1)
    #expect(options.first?.captureMicrophone == true)
    #expect(options.first?.captureSystemAudio == false)
}

@MainActor
@Test("The microphone stays off unless it was asked for")
func microphoneIsOffByDefault() async {
    // §4.10 rung 2: the microphone prompt is paid only when someone
    // deliberately enables it.
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let host = makeHost(coordinator: coordinator, recorder: recorder)

    _ = await host.handle(startBody())

    let options = await coordinator.receivedOptions
    #expect(options.first?.captureMicrophone == false)
    #expect(options.first?.captureSystemAudio == true)
}

// MARK: - Important 2: the marker handler

@MainActor
@Test("A mark on the agent's own session returns its offset")
func markOnOwnedSessionReturnsTheOffset() async {
    // No test ever constructed `.mark(...)` and called `handle`, so the whole
    // marker request path — consent gate, coordinator call, response shape —
    // was unexercised; `markCalls` was recorded and never asserted.
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let host = makeHost(coordinator: coordinator, recorder: recorder)

    let started = await host.handle(startBody())
    guard case .started(let sessionID, _) = started else {
        Issue.record("expected a started response, got \(started)")
        return
    }

    let response = await host.handle(.mark(sessionID: sessionID, label: "ran the tests"))
    #expect(response == .marked(timeSeconds: 12.5))

    let calls = await coordinator.markCalls
    #expect(calls.count == 1)
    #expect(calls.first?.sessionID == sessionID)
    #expect(calls.first?.label == "ran the tests",
            "the label is the whole point of a marker — it must not be dropped")
}

@MainActor
@Test("A mark on someone else's session is refused, not silently landed")
func markOnAnotherSessionIsRefused() async {
    // The leak this guards: a marker landing in a human's recording because a
    // stale session id was accepted is the same class of defect as handing an
    // agent someone else's bundle path.
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let host = makeHost(coordinator: coordinator, recorder: recorder)

    _ = await host.handle(startBody())
    let response = await host.handle(.mark(sessionID: "not-mine", label: nil))

    guard case .failure(let error) = response else {
        Issue.record("expected a refusal, got \(response)")
        return
    }
    #expect(error.code == .noSuchSession)
    #expect(error.hint?.contains("snitt status") == true)
}

@MainActor
@Test("A mark from an agent that may not record never reaches the coordinator")
func markIsGatedByConsent() async {
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let host = AutomationHost(coordinator: coordinator,
                              settings: { AgentSettings(agentRecordingEnabled: false) },
                              onRecordingState: { state in recorder.record(state) },
                              auditLogURL: scratchAuditLogURL())

    let response = await host.handle(.mark(sessionID: "s1", label: nil))
    guard case .failure(let error) = response else {
        Issue.record("expected a refusal, got \(response)")
        return
    }
    #expect(error.code == .consentRequired)
    #expect(await coordinator.markCalls.isEmpty)
}

@MainActor
@Test("A session ended by the human kill switch is audited as such")
func killSwitchStopIsAudited() async throws {
    // §5.3's kill switch is a person stopping agent work nobody was
    // watching, and §12's audit exists so that incident is reconstructable.
    // Before this, `clearAgentSession` forgot the session id without
    // recording an end, so the trail showed a start and nothing after it —
    // reading as PERMANENTLY IN-FLIGHT when in fact a human intervened,
    // which is the opposite of what happened.
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let auditLogURL = scratchAuditLogURL()
    let host = makeHost(coordinator: coordinator, recorder: recorder, auditLogURL: auditLogURL)

    let started = await host.handle(startBody())
    guard case .started(let sessionID, _) = started else {
        Issue.record("expected a started response, got \(started)")
        return
    }

    // What AppDelegate calls when a person stops from the menu bar.
    await host.clearAgentSession()

    let records = try AuditLog.read(from: auditLogURL)
    let mine = records.filter { $0.sessionID == sessionID }
    #expect(mine.count == 2, "a kill-switch stop must close the session, not leave it open")
    // Distinct from `completed` deliberately: an incident review needs to
    // see that a human intervened, not that the agent finished normally.
    #expect(mine.last?.outcome == "stoppedByHuman")
    #expect(mine.last?.endedAt != nil)
}

@MainActor
@Test("Clearing with no agent session writes nothing")
func clearWithoutAgentSessionWritesNothing() async throws {
    // `clearAgentSession` also fires when a HUMAN starts or stops their own
    // recording. §12 scopes the audit to agent-initiated work, so this path
    // must stay silent — an implementation that writes unconditionally
    // buries the agent entries the audit exists to surface.
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let auditLogURL = scratchAuditLogURL()
    let host = makeHost(coordinator: coordinator, recorder: recorder, auditLogURL: auditLogURL)

    await host.clearAgentSession()

    #expect(try AuditLog.read(from: auditLogURL).isEmpty)
}

// MARK: - Diagnostics export

@MainActor
@Test("The host writes the diagnostics file and returns the report")
func hostWritesDiagnostics() async throws {
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let auditLogURL = scratchAuditLogURL()
    try AuditLog.append(AuditRecord(sessionID: "S1", target: "Safari", initiator: "agent",
                                    startedAt: Date()), to: auditLogURL)
    let host = makeHost(coordinator: coordinator, recorder: recorder, auditLogURL: auditLogURL)

    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("snitt-diagnostics-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: out) }

    let response = await host.handle(.diagnostics(outputPath: out.path))

    guard case .diagnosticsWritten(let report) = response else {
        Issue.record("expected .diagnosticsWritten, got \(response)")
        return
    }
    // The discriminating assertion: the FILE actually exists on disk with
    // the report's own content. An implementation that builds the report
    // in memory and returns `.diagnosticsWritten` without ever calling
    // `DiagnosticsBundle.write` (or that calls it and discards the throw)
    // would pass a check on the response value alone.
    #expect(FileManager.default.fileExists(atPath: out.path))
    // `.iso8601` matches `DiagnosticsBundle.write`'s own encoder — dates in
    // the exported file are human-readable text, not raw epoch doubles.
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(DiagnosticsReport.self, from: Data(contentsOf: out))
    #expect(decoded.appVersion == report.appVersion)
    #expect(decoded.recentSessions.count == 1)
    #expect(decoded.recentSessions[0].sessionID == "S1")
}

@MainActor
@Test("A diagnostics export that cannot write its file is reported as a failure")
func diagnosticsExportFailureIsReported() async {
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let host = makeHost(coordinator: coordinator, recorder: recorder)

    // A directory that does not exist: `DiagnosticsBundle.write` must throw
    // rather than the host reporting success for a file it never wrote.
    let badPath = "/nonexistent-\(UUID().uuidString)/diagnostics.json"

    let response = await host.handle(.diagnostics(outputPath: badPath))
    guard case .failure(let error) = response else {
        Issue.record("expected a failure for an unwritable path, got \(response)")
        return
    }
    #expect(error.code == .internalError)
}

// MARK: - Pause / resume (M5e, D53)

/// The capture-side behaviour is `PauseResumeTests`. These cover the contract
/// an agent meets: only the session that started a recording may pause it, and
/// `status` reports the paused state at all — D53's point being that an agent
/// which pauses, crashes and restarts has no other way to discover it left a
/// session frozen.
@MainActor
struct PauseAutomationTests {
    @Test("Pause and resume reach the coordinator with the session and direction")
    func pauseReachesTheCoordinator() async throws {
        let coordinator = FakeCoordinator()
        let host = makeHost(coordinator: coordinator, recorder: StateRecorder())
        _ = await host.handle(.startRecording(StartOptions(bundleIdentifier: "com.apple.Safari")))
        let session = try #require(await coordinator.startCalls.first)

        _ = await host.handle(.pauseRecording(sessionID: session))
        _ = await host.handle(.resumeRecording(sessionID: session))

        #expect(await coordinator.pauseCalls.map(\.paused) == [true, false])
        #expect(await coordinator.pauseCalls.allSatisfy { $0.session == session })
    }

    @Test("A session that is not yours cannot be paused")
    func foreignSessionIsRefused() async throws {
        // §5.3's posture: a person at the machine stays in control of their own
        // recording. Freezing it from outside is the opposite, and an agent
        // guessing a session id must not be able to.
        let coordinator = FakeCoordinator()
        let host = makeHost(coordinator: coordinator, recorder: StateRecorder())
        _ = await host.handle(.startRecording(StartOptions(bundleIdentifier: "com.apple.Safari")))

        guard case .failure(let error) = await host.handle(.pauseRecording(sessionID: "THEIRS")) else {
            Issue.record("pausing another session was allowed"); return
        }
        #expect(error.code == .noSuchSession)
    }

    @Test("Status reports the paused state, not merely that a recording exists")
    func statusReportsPaused() async throws {
        // `recording: true` for a paused session is true and useless — exactly
        // what an agent recovering from a crash would misread.
        let coordinator = FakeCoordinator()
        let host = makeHost(coordinator: coordinator, recorder: StateRecorder())
        _ = await host.handle(.startRecording(StartOptions(bundleIdentifier: "com.apple.Safari")))
        await coordinator.setPausedForTesting(true, seconds: 12)

        guard case .status(let info) = await host.handle(.status) else {
            Issue.record("status did not return status"); return
        }
        #expect(info.paused, "a paused session reported itself as merely recording")
        #expect(info.pausedSeconds == 12)
    }

    @Test("Pausing returns the new state, so no second round trip is needed")
    func pauseReturnsTheNewStatus() async throws {
        let coordinator = FakeCoordinator()
        let host = makeHost(coordinator: coordinator, recorder: StateRecorder())
        _ = await host.handle(.startRecording(StartOptions(bundleIdentifier: "com.apple.Safari")))
        let session = try #require(await coordinator.startCalls.first)

        guard case .status(let info) = await host.handle(.pauseRecording(sessionID: session)) else {
            Issue.record("pause did not return a status"); return
        }
        #expect(info.paused)
    }
}

// MARK: - Screenshot (M5e, D53's correlation primitive)

@MainActor
struct ScreenshotAutomationTests {
    @Test("The frame's offset is passed through, not restamped by the host")
    func offsetIsPassedThrough() async throws {
        // D53's guarantee lives in the Recorder — the image and its marker come
        // from one frame. A host that computed its own "now" here would put the
        // reported time somewhere else than the marker, reintroducing exactly
        // the drift the primitive exists to remove.
        let coordinator = FakeCoordinator()
        let host = makeHost(coordinator: coordinator, recorder: StateRecorder())
        _ = await host.handle(.startRecording(StartOptions(bundleIdentifier: "com.apple.Safari")))
        let session = try #require(await coordinator.startCalls.first)

        guard case .screenshotTaken(let path, let time) =
                await host.handle(.screenshot(sessionID: session, label: "after save")) else {
            Issue.record("screenshot did not return a screenshot"); return
        }
        #expect(time == 4.25, "the host restamped the offset")
        #expect(path == "/tmp/shot.png")
        #expect(await coordinator.screenshotCalls.first?.label == "after save")
    }

    @Test("Another session's screen cannot be photographed")
    func foreignSessionIsRefused() async throws {
        // The most obviously sensitive thing this surface could hand out is a
        // picture of someone else's screen. §5's posture makes that Snitt's
        // problem, not the caller's.
        let coordinator = FakeCoordinator()
        let host = makeHost(coordinator: coordinator, recorder: StateRecorder())
        _ = await host.handle(.startRecording(StartOptions(bundleIdentifier: "com.apple.Safari")))

        guard case .failure(let error) =
                await host.handle(.screenshot(sessionID: "THEIRS", label: nil)) else {
            Issue.record("photographing another session was allowed"); return
        }
        #expect(error.code == .noSuchSession)
    }

    @Test("No frame yet is a retryable answer, not a broken recording")
    func noFrameYetIsDistinct() async throws {
        // Telling an agent the session is gone would make it stop and restart a
        // recording that is perfectly healthy and half a frame old.
        let coordinator = FakeCoordinator()
        let host = makeHost(coordinator: coordinator, recorder: StateRecorder())
        _ = await host.handle(.startRecording(StartOptions(bundleIdentifier: "com.apple.Safari")))
        let session = try #require(await coordinator.startCalls.first)
        await coordinator.setScreenshotResult(.noFrameYet)

        guard case .failure(let error) =
                await host.handle(.screenshot(sessionID: session, label: nil)) else {
            Issue.record("expected a failure"); return
        }
        #expect(error.code != .noSuchSession,
                "a healthy recording was reported as a missing session")
        #expect(error.hint?.contains("try again") == true)
    }
}

// MARK: - Reported input (M5e follow-on)

/// The agent surface for input the OS never saw.
@MainActor
struct ReportedInputAutomationTests {
    private func startedHost() async -> (FakeCoordinator, AutomationHost, String) {
        let coordinator = FakeCoordinator()
        let host = makeHost(coordinator: coordinator, recorder: StateRecorder())
        _ = await host.handle(.startRecording(StartOptions(bundleIdentifier: "com.apple.Safari")))
        let session = await coordinator.startCalls.first ?? ""
        return (coordinator, host, session)
    }

    @Test("A reported click reaches the coordinator with its position")
    func clickReachesTheCoordinator() async throws {
        let (coordinator, host, session) = await startedHost()
        _ = await host.handle(.reportInput(sessionID: session, kind: "click",
                                           x: 0.25, y: 0.75, label: nil))
        let reported = try #require(await coordinator.reportedInput.first)
        #expect(reported.kind == .click)
        #expect(reported.x == 0.25 && reported.y == 0.75)
    }

    @Test("A reported keystroke is a beat, with no position")
    func keystrokesAreReportedAsBeats() async throws {
        // Amended (D72, 2026-09-08). Keystrokes used to be refused outright:
        // reporting one "would be a claim about what a PERSON typed, written
        // into a recording that never observed it". That reasoning is about
        // CONTENT, and the amendment keeps it — see below. What it no longer
        // blocks is the TIMING, which is all `autoTrimRange` reads and the only
        // signal an agent driving a terminal can offer.
        let (coordinator, host, session) = await startedHost()
        _ = await host.handle(
            .reportInput(sessionID: session, kind: "keystroke", x: nil, y: nil, label: nil))
        let reported = try #require(await coordinator.reportedInput.first)
        #expect(reported.kind == .keystroke)
        // Nil, not zero: zero is the top-left corner of the window, and a
        // keystroke happened at no corner.
        #expect(reported.x == nil && reported.y == nil)
    }

    @Test("A reported keystroke carrying text is still refused")
    func keystrokeContentIsStillRefused() async throws {
        // The half of the original rule that survives, and the reason the
        // other half could be relaxed: a beat says "I typed at this instant",
        // which is the claim `cursor` was already trusted to make. Text would
        // say WHAT was typed — a claim about content Snitt never saw, which is
        // what §5.6 governs.
        let (coordinator, host, session) = await startedHost()
        guard case .failure = await host.handle(
            .reportInput(sessionID: session, kind: "keystroke",
                         x: nil, y: nil, label: "sudo rm -rf /"))
        else { Issue.record("a keystroke with text was accepted"); return }
        #expect(await coordinator.reportedInput.isEmpty)
    }

    @Test("Input cannot be reported into another session's recording")
    func foreignSessionIsRefused() async throws {
        // Otherwise an agent could write input into a person's recording.
        let (coordinator, host, _) = await startedHost()
        guard case .failure(let error) = await host.handle(
            .reportInput(sessionID: "THEIRS", kind: "click", x: 0.5, y: 0.5, label: nil))
        else { Issue.record("reporting into another session was allowed"); return }
        #expect(error.code == .noSuchSession)
        #expect(await coordinator.reportedInput.isEmpty)
    }

    @Test("An unknown kind is refused rather than silently dropped")
    func unknownKindIsRefused() async throws {
        let (_, host, session) = await startedHost()
        guard case .failure = await host.handle(
            .reportInput(sessionID: session, kind: "wiggle", x: 0.5, y: 0.5, label: nil))
        else { Issue.record("an unknown kind was accepted"); return }
    }
}
