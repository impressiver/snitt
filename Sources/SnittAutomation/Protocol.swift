import Foundation

public enum AutomationProtocol {
    /// Bumped whenever the wire format changes incompatibly. The server refuses
    /// mismatches rather than guessing (§10).
    ///
    /// 2 — added `.mark` and `StartOptions.workingDirectory`. The new request
    /// case is why this is a bump and not an additive change: an old app cannot
    /// decode `.mark` and would report `internal_error`, where §10 wants a
    /// refusal that says what to do.
    public static let version = 2
}

public struct StartOptions: Codable, Sendable, Equatable {
    public var bundleIdentifier: String?
    public var displayID: UInt32?
    public var microphone: Bool
    public var systemAudio: Bool
    public var maxDurationSeconds: Double?
    /// The client's working directory, used to discover git context (§7).
    ///
    /// Filled by the CLI, not the app: `Snitt.app`'s own directory is `/`, so it
    /// cannot know which repository a recording is about. Hotkey recordings have
    /// no working directory and therefore no git context, which is correct —
    /// pressing a key is not associated with a checkout.
    public var workingDirectory: String?

    public init(bundleIdentifier: String? = nil,
                displayID: UInt32? = nil,
                microphone: Bool = false,
                systemAudio: Bool = true,
                maxDurationSeconds: Double? = nil,
                workingDirectory: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.displayID = displayID
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.maxDurationSeconds = maxDurationSeconds
        self.workingDirectory = workingDirectory
    }
}

public struct AutomationRequest: Codable, Sendable {
    public enum Body: Codable, Sendable {
        case handshake
        case listTargets
        case startRecording(StartOptions)
        case stopRecording(sessionID: String)
        case status
        case mark(sessionID: String, label: String?)
    }

    public var protocolVersion: Int
    public var body: Body

    public init(protocolVersion: Int = AutomationProtocol.version, body: Body) {
        self.protocolVersion = protocolVersion
        self.body = body
    }
}

public struct TargetSummary: Codable, Sendable, Equatable {
    public var id: UInt32
    public var kind: String
    public var title: String?
    public var applicationName: String?
    public var bundleIdentifier: String?

    public init(id: UInt32, kind: String, title: String?,
                applicationName: String?, bundleIdentifier: String?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct HandshakeInfo: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var appVersion: String
    public init(protocolVersion: Int, appVersion: String) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
    }
}

public struct StatusInfo: Codable, Sendable, Equatable {
    public var recording: Bool
    public var sessionID: String?
    public var elapsedSeconds: Double?
    public init(recording: Bool, sessionID: String?, elapsedSeconds: Double?) {
        self.recording = recording
        self.sessionID = sessionID
        self.elapsedSeconds = elapsedSeconds
    }
}

public struct AutomationError: Codable, Sendable, Equatable, Error {
    /// The agent-facing contract. An agent branches on this, never on `message`.
    /// Adding a case is safe; renaming one is a breaking protocol change.
    public enum Code: String, Codable, Sendable, CaseIterable {
        case consentRequired = "consent_required"
        case upgradeRequired = "upgrade_required"
        case noSuchSession = "no_such_session"
        case alreadyRecording = "already_recording"
        case targetNotFound = "target_not_found"
        case permissionDenied = "permission_denied"
        case internalError = "internal_error"
    }

    public var code: Code
    public var message: String
    public var hint: String?

    public init(code: Code, message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }

    /// Distinct, non-zero exit codes so a shell script can branch without parsing
    /// JSON. Success is 0.
    public static let exitCode: [Code: Int32] = [
        .consentRequired: 10,
        .upgradeRequired: 11,
        .noSuchSession: 12,
        .alreadyRecording: 13,
        .targetNotFound: 14,
        .permissionDenied: 15,
        .internalError: 16,
    ]
}

public enum AutomationResponse: Codable, Sendable, Equatable {
    case handshake(HandshakeInfo)
    case targets([TargetSummary])
    case started(sessionID: String, target: String)
    case stopped(bundlePath: String)
    case status(StatusInfo)
    case failure(AutomationError)
    case marked(timeSeconds: Double)
}
