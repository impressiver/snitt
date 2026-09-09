import Foundation
import SnittDocument

public enum AutomationProtocol {
    /// Bumped whenever the wire format changes incompatibly. The server refuses
    /// mismatches rather than guessing (§10).
    ///
    /// 2 — added `.mark` and `StartOptions.workingDirectory`. The new request
    /// case is why this is a bump and not an additive change: an old app cannot
    /// decode `.mark` and would report `internal_error`, where §10 wants a
    /// refusal that says what to do.
    ///
    /// v2 was later amended again to add `.inspect`/`.inspected`, still without
    /// a further bump: v2 has never shipped — `main` has no `SnittAutomation`
    /// at all, and both PRs that would introduce it are unmerged — so there is
    /// no released v2 client whose compatibility a bump would protect. A future
    /// reader should not mistake this for a forgotten bump; it is deliberate,
    /// for the same reason `.stopped(health:)` amended v2 rather than bumping.
    ///
    /// v2 was amended a third time to add `.trim`/`.trimmed` and
    /// `.export`/`.exported`, for the same reason: still no released v2
    /// client. Trim and export run in the app rather than the CLI, for the
    /// same reason `.inspect` does — the client cannot assume it can read
    /// the bundle (§4.9): the output directory is user-configurable and,
    /// even at its current default (`~/Documents/Snitt`), may still be
    /// pointed at a TCC-gated location like `~/Desktop`.
    ///
    /// v2 was amended a fourth time to add `maxSizeBytes` to `.export`
    /// (M3d), for the same reason: still no released v2 client.
    ///
    /// v2 was amended a fifth time to add `.diagnostics`/`.diagnosticsWritten`
    /// (M5a, Task 6), for the same reason: still no released v2 client.
    /// Diagnostics runs in the app rather than the CLI for a different
    /// reason than `.inspect`/`.trim`/`.export` do — not TCC, but process
    /// scope: `OSLogStore(scope: .currentProcessIdentifier)` (spike S8)
    /// reads back only the calling process's own log entries, so a CLI-side
    /// implementation would bundle the CLI's own handful of lines and none
    /// of the app's.
    ///
    /// v2 was amended a sixth time to add `crashReportingEnabled` and
    /// `crashReports` to `DiagnosticsReport` (§12's opt-in local crash
    /// reporting), for the same reason: still no released v2 client. Both
    /// fields are non-optional, so a NEW client decoding an OLD app's
    /// response would fail `keyNotFound` — acceptable only because there is
    /// no old client to break; a real v2 release would need this amendment
    /// to be additive-and-optional instead, or a bump.
    /// 3 — added `.crop`/`.cropped`. A bump rather than another additive
    /// amendment: unlike every earlier change to v2, **v0.1.0 has shipped**, so
    /// there IS a released client whose compatibility a silent case addition
    /// would break — an old app receiving `.crop` cannot decode it and reports
    /// `internal_error` where §10 wants a refusal that says what to do.
    ///
    /// The blast radius is small because D63 now embeds `snitt` and `snitt-mcp`
    /// inside `Snitt.app`, so client and app ship and update together; a
    /// mismatched pair means someone is running a loose binary from an old
    /// build, which is exactly the case the handshake should refuse loudly.
    public static let version = 3
}

public struct StartOptions: Codable, Sendable, Equatable {
    public var bundleIdentifier: String?
    /// A window id from THIS session's `listTargets`, naming exactly one
    /// window. Without it, an app with several windows is ambiguous and the
    /// agent path refuses rather than guessing (see
    /// `TargetResolutionError.ambiguousWindows`).
    public var windowID: UInt32?
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
                windowID: UInt32? = nil,
                displayID: UInt32? = nil,
                microphone: Bool = false,
                systemAudio: Bool = true,
                maxDurationSeconds: Double? = nil,
                workingDirectory: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.windowID = windowID
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
        case inspect(bundlePath: String)
        case trim(bundlePath: String, start: Double?, end: Double?, auto: Bool)
        /// A `nil` rect REMOVES the crop, which is distinct from cropping to
        /// the full frame only in what reaches disk.
        case crop(bundlePath: String, rect: CropRect?)
        /// M5e/D53. Amends v3 rather than bumping it again: v3 has not
        /// shipped, so there is no released client for these to break — the
        /// same reasoning v2 used for every addition before v0.1.0 existed,
        /// and it expires the moment v3 ships.
        case pauseRecording(sessionID: String)
        case resumeRecording(sessionID: String)
        case screenshot(sessionID: String, label: String?)
        /// An input event the OS never saw, reported by whoever caused it
        /// (M5e follow-on). `x`/`y` are fractions of the recorded window.
        case reportInput(sessionID: String, kind: String,
                         x: Double, y: Double, label: String?)
        /// D57's automatic trim. Carries the resolved criteria rather than a
        /// preset name, so the CLI's per-criterion flags and its `--preset`
        /// arrive here as the same thing and the app has one code path.
        case autoDeepTrim(bundlePath: String, criteria: DeepTrimCriteria)
        case export(bundlePath: String, format: String, outputPath: String,
                    scale: Double, chapters: Bool, subtitles: Bool, maxSizeBytes: Int?)
        /// `outputPath` arrives already resolved against the CALLER's working
        /// directory (`PathResolver.resolve`, done by the CLI before this is
        /// sent) — never the app's, whose own cwd is not the caller's (M3c
        /// finding #3, the same reason `.trim`/`.export`'s paths are
        /// pre-resolved).
        case diagnostics(outputPath: String)
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
    /// WALL time since the session started, including any time paused — the
    /// same clock `maxDuration` is measured on, so an agent can tell how close
    /// it is to the cap.
    public var elapsedSeconds: Double?
    /// D53: an agent that pauses, crashes and is restarted has no other way to
    /// discover it left a session paused. `recording` alone reads as "yes" for
    /// a paused session, which is true and useless.
    public var paused: Bool
    /// How much of `elapsedSeconds` was spent paused. `elapsed - paused` is the
    /// footage.
    public var pausedSeconds: Double?

    public init(recording: Bool, sessionID: String?, elapsedSeconds: Double?,
                paused: Bool = false, pausedSeconds: Double? = nil) {
        self.recording = recording
        self.sessionID = sessionID
        self.elapsedSeconds = elapsedSeconds
        self.paused = paused
        self.pausedSeconds = pausedSeconds
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

/// Renders §12.1's health metrics for display, omitting any metric that is
/// absent rather than reporting it as null or zero.
///
/// Shared by both frontends (§4.8: the CLI and the MCP server must not
/// diverge) so "absent means absent" is enforced in exactly one place. A nil
/// `CaptureHealth` — or a nil field within one — yields no key at all: an
/// agent branching on key PRESENCE must see a dead microphone as absent, not
/// as a reported measurement of zero or `null`.
public func healthFields(_ health: CaptureHealth?) -> [String: Double] {
    guard let health else { return [:] }
    var fields: [String: Double] = [:]
    if let v = health.meanFrameVariance { fields["meanFrameVariance"] = v }
    if let m = health.micRMS { fields["micRMS"] = m }
    if let s = health.systemAudioRMS { fields["systemAudioRMS"] = s }
    return fields
}

/// Renders `ExportManifest`'s size-budget honesty for display — the same
/// property this milestone spent its whole effort making `maxSizeMet` report
/// truthfully, one layer up: a human-readable summary is not "the JSON has
/// the field," it is a sentence a reader (or an agent) actually sees.
///
/// Shared by both frontends (§4.8, same reasoning as `healthFields`): if the
/// CLI and the MCP server each wrote their own wording, one of them would
/// eventually drift into announcing success sentences for a file that
/// missed its budget, silently. Returns `nil` when there is nothing to say —
/// no target was requested, or the target was met — so a caller appends this
/// only when it is non-nil rather than always emitting a trailing clause.
public func sizeBudgetNote(_ manifest: ExportManifest) -> String? {
    guard manifest.maxSizeMet == false, let maxSizeBytes = manifest.maxSizeBytes else {
        return nil
    }
    let actualMB = Double(manifest.byteSize) / 1_000_000
    let requestedMB = Double(maxSizeBytes) / 1_000_000
    return "over budget: \(String(format: "%.1f", actualMB)) MB > "
         + "\(String(format: "%.1f", requestedMB)) MB requested"
}

public enum AutomationResponse: Codable, Sendable, Equatable {
    case handshake(HandshakeInfo)
    case targets([TargetSummary])
    case started(sessionID: String, target: String)
    /// `health` was added to an already-Codable case without bumping
    /// `AutomationProtocol.version`. That is correct, not an oversight: v2 has
    /// never shipped — `main` has no `SnittAutomation` at all, and both PRs
    /// that would introduce it are unmerged — so there is no released v2
    /// client to stay compatible with. Amending an unreleased version is the
    /// right move; bumping to 3 would falsely imply a compatibility break
    /// against a version nobody has.
    case stopped(bundlePath: String, health: CaptureHealth?)
    case status(StatusInfo)
    case failure(AutomationError)
    case marked(timeSeconds: Double)
    case inspected(InspectReport)
    case trimmed(TrimSummary)
    case cropped(CropSummary)
    case autoTrimmed(AutoTrimSummary)
    case screenshotTaken(path: String, timeSeconds: Double)
    case exported(ExportManifest)
    case diagnosticsWritten(DiagnosticsReport)
}

/// What a trim produced, for a caller that cannot inspect `edit.json` itself
/// (the same reason `ExportManifest` exists — see its doc comment).
/// What a crop did, in PIXELS as well as fractions.
///
/// An agent cannot look at the video (§8's reason `snitt inspect` exists), so
/// "0.5 x 0.5" is not an answer it can act on — it needs the dimensions its
/// export will actually have, which is also what `--max-size` reasons about.
public struct CropSummary: Codable, Sendable, Equatable {
    public var crop: CropRect?
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(crop: CropRect?, pixelWidth: Int, pixelHeight: Int) {
        self.crop = crop
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// What an automatic trim removed (D57).
public struct AutoTrimSummary: Codable, Sendable, Equatable {
    /// Spans this run removed. Zero is a normal outcome, not a failure — the
    /// recording simply had no dead air by the criteria asked for.
    public var spans: Int
    public var seconds: Double
    /// Cuts in the recording afterwards, INCLUDING any that were already
    /// there. Reported separately from `spans` because re-running is expected
    /// and a caller needs to distinguish "added nothing" from "there is
    /// nothing here".
    public var totalCuts: Int
    /// Output duration after the trim.
    public var remainingSeconds: Double

    public init(spans: Int, seconds: Double, totalCuts: Int, remainingSeconds: Double) {
        self.spans = spans
        self.seconds = seconds
        self.totalCuts = totalCuts
        self.remainingSeconds = remainingSeconds
    }
}

public struct TrimSummary: Codable, Sendable, Equatable {
    public var keptSeconds: Double
    public var cutSeconds: Double
    public var cuts: [TimeRange]

    public init(keptSeconds: Double, cutSeconds: Double, cuts: [TimeRange]) {
        self.keptSeconds = keptSeconds
        self.cutSeconds = cutSeconds
        self.cuts = cuts
    }
}
