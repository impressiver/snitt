import Foundation
import SnittAutomation
import SnittCapture

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
final class AutomationHost: AutomationHandling, @unchecked Sendable {
    /// Pushes recording state at the menu bar. `@MainActor` because that is
    /// where `StatusItemController` lives; deliberately not `@Sendable`, so it
    /// can capture the main-actor-isolated app delegate directly.
    typealias RecordingStateSink = @MainActor (RecordingState) -> Void

    private let coordinator: any AgentRecordingControlling
    private let settings: @Sendable () -> AgentSettings
    private let onRecordingState: RecordingStateSink
    private let registry = SessionRegistry()
    private var server: AutomationServer?


    init(coordinator: any AgentRecordingControlling,
         settings: @escaping @Sendable () -> AgentSettings,
         onRecordingState: @escaping RecordingStateSink = { _ in }) {
        self.coordinator = coordinator
        self.settings = settings
        self.onRecordingState = onRecordingState
    }

    private func pushState(_ state: RecordingState) async {
        let sink = onRecordingState
        await MainActor.run { sink(state) }
    }

    /// Forgets any agent session, without touching the coordinator.
    ///
    /// Called by `AppDelegate` whenever a HUMAN starts or stops a recording. The
    /// coordinator already invalidates the agent's session id on any stop; this
    /// is the registry's half, so `snitt status` stops claiming a recording that
    /// a person ended from the menu bar.
    func clearAgentSession() async {
        await registry.closeAny()
    }

    func start() {
        let server = AutomationServer(socketURL: SocketPath.url(), handler: self)
        try? server.start()
        self.server = server
    }

    func stop() {
        server?.stop()
        server = nil
    }

    func handle(_ body: AutomationRequest.Body) async -> AutomationResponse {
        switch body {
        case .handshake:
            return .handshake(HandshakeInfo(protocolVersion: AutomationProtocol.version,
                                            appVersion: "0.1.0"))

        case .status:
            return .status(await registry.current(now: Date()))

        case .listTargets:
            return await listTargets()

        case .startRecording(let options):
            return await start(options)

        case .stopRecording(let sessionID):
            return await stop(sessionID)
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
            sessionID = try await registry.open(maxDuration: maxDuration, now: Date())
        } catch let error as AutomationError {
            return .failure(error)
        } catch {
            return .failure(AutomationError(code: .internalError,
                                            message: "Could not open a session."))
        }

        let reference: TargetReference
        if let bundleID = options.bundleIdentifier {
            reference = .window(bundleIdentifier: bundleID, titleHint: nil)
        } else if let displayID = options.displayID {
            reference = .display(id: displayID)
        } else {
            try? await registry.close(sessionID)
            return .failure(AutomationError(code: .targetNotFound,
                                            message: "No target was specified."))
        }

        let outcome = await coordinator.startForAgent(sessionID: sessionID,
                                                      reference: reference)
        switch outcome {
        case .started(let name, _):
            await pushState(.recording(startedAt: Date()))
            return .started(sessionID: sessionID, target: name)
        default:
            try? await registry.close(sessionID)
            return .failure(Self.error(for: outcome))
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
        case .stopped(let url, _):
            try? await registry.close(sessionID)
            await pushState(.idle)
            return .stopped(bundlePath: url.path)

        case .notCurrentSession:
            // Either the id was never valid, or a person already ended it. Drop
            // the registry entry if it names this session so `snitt status` and
            // the next `record start` agree with reality — but stop nothing.
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
            try? await registry.close(sessionID)
            await pushState(.idle)
            return .failure(AutomationError(code: .internalError,
                                            message: "The recording did not finalize.",
                                            hint: message))
        }
    }
}
