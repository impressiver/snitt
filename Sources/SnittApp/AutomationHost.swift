import Foundation
import SnittAutomation
import SnittCapture

/// Bridges automation requests to the same recording machinery the hotkey uses.
///
/// Requests arrive off the main actor; anything touching the coordinator or the
/// status item hops to it. Agent recordings go through the SAME coordinator as
/// hotkey presses, so M2a's transition guard, visible indicator and kill switch
/// all apply to them without a second implementation (§5.3).
final class AutomationHost: AutomationHandling, @unchecked Sendable {
    private let coordinator: RecordingCoordinator
    private let settings: @Sendable () -> AgentSettings
    private let registry = SessionRegistry()
    private var server: AutomationServer?

    init(coordinator: RecordingCoordinator,
         settings: @escaping @Sendable () -> AgentSettings) {
        self.coordinator = coordinator
        self.settings = settings
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

        let outcome = await coordinator.startForAgent(reference: reference)
        switch outcome {
        case .started(let name, _):
            return .started(sessionID: sessionID, target: name)
        default:
            try? await registry.close(sessionID)
            return .failure(AutomationError(
                code: .targetNotFound,
                message: "Could not start recording that target.",
                hint: "Check `snitt targets list` — the application may not be running."))
        }
    }

    private func stop(_ sessionID: String) async -> AutomationResponse {
        do {
            try await registry.close(sessionID)
        } catch let error as AutomationError {
            return .failure(error)
        } catch {
            return .failure(AutomationError(code: .internalError,
                                            message: "Could not close the session."))
        }

        guard let outcome = await coordinator.stopIfRecording(),
              case .stopped(let url, _) = outcome else {
            return .failure(AutomationError(code: .internalError,
                                            message: "The recording did not finalize."))
        }
        return .stopped(bundlePath: url.path)
    }
}
