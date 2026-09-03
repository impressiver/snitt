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
    private(set) var markCalls: [String] = []

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
                       git: GitContext?) async -> CoordinatorOutcome {
        startCalls.append(sessionID)
        if case .started = startOutcome { activeSession = sessionID }
        return startOutcome
    }

    func stopForAgent(sessionID: String) async -> AgentStopResult {
        stopCalls.append(sessionID)
        if let stopOverride { return stopOverride }
        guard activeSession == sessionID else { return .notCurrentSession }
        activeSession = nil
        return .stopped(URL(fileURLWithPath: "/tmp/agent-\(sessionID).snitt"), copied: true)
    }

    func markForAgent(sessionID: String, label: String?) async -> AgentMarkResult {
        markCalls.append(sessionID)
        guard activeSession == sessionID else { return .notCurrentSession }
        return .marked(0)
    }
}

/// Records what the menu bar was told, in order.
@MainActor
final class StateRecorder {
    private(set) var states: [RecordingState] = []
    func record(_ state: RecordingState) { states.append(state) }
}

@MainActor
private func makeHost(coordinator: FakeCoordinator,
                      recorder: StateRecorder,
                      fullDisplayAllowed: Bool = false) -> AutomationHost {
    AutomationHost(
        coordinator: coordinator,
        settings: { AgentSettings(agentRecordingEnabled: true,
                                  fullDisplayAllowed: fullDisplayAllowed) },
        onRecordingState: { state in recorder.record(state) })
}

private func startBody(maxDuration: Double? = nil) -> AutomationRequest.Body {
    .startRecording(StartOptions(bundleIdentifier: "com.example.App",
                                 maxDurationSeconds: maxDuration))
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
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let host = makeHost(coordinator: coordinator, recorder: recorder)

    // A cap below the 600s ceiling passes through `effectiveMaxDuration`
    // unchanged, so this is the real production path and not a test-only knob.
    let started = await host.handle(startBody(maxDuration: 0.2))
    guard case .started(let sessionID, _) = started else {
        Issue.record("expected a started response, got \(started)")
        return
    }

    var stopped: [String] = []
    for _ in 0..<40 {
        try await Task.sleep(for: .milliseconds(50))
        stopped = await coordinator.stopCalls
        if !stopped.isEmpty { break }
    }
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
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let host = makeHost(coordinator: coordinator, recorder: recorder)

    let started = await host.handle(startBody(maxDuration: 0.2))
    guard case .started(let sessionID, _) = started else {
        Issue.record("expected a started response, got \(started)")
        return
    }
    // A person stops it from the menu bar, then starts their own recording.
    await coordinator.humanStops()
    await host.clearAgentSession()

    try await Task.sleep(for: .milliseconds(600))

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
    let host = makeHost(coordinator: coordinator, recorder: recorder)

    let started = await host.handle(startBody(maxDuration: 0.2))
    guard case .started(let sessionID, _) = started else {
        Issue.record("expected a started response, got \(started)")
        return
    }
    await coordinator.setStopOverride(.failed("writer would not finalize"))

    for _ in 0..<40 {
        try await Task.sleep(for: .milliseconds(50))
        if await !coordinator.stopCalls.isEmpty { break }
    }
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
    let coordinator = FakeCoordinator()
    let recorder = StateRecorder()
    let host = makeHost(coordinator: coordinator, recorder: recorder)

    let started = await host.handle(startBody(maxDuration: 0.2))
    guard case .started(let sessionID, _) = started else {
        Issue.record("expected a started response, got \(started)")
        return
    }
    await coordinator.setStopOverride(.busy)

    for _ in 0..<40 {
        try await Task.sleep(for: .milliseconds(50))
        if await !coordinator.stopCalls.isEmpty { break }
    }
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
                              onRecordingState: { state in recorder.record(state) })

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
