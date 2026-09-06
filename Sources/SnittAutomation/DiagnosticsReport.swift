import Foundation
import SnittDocument

/// A support bundle: what `snitt diagnostics export` writes.
///
/// Defined here, not in `SnittApp` alongside `DiagnosticsBundle` that builds
/// it, because `AutomationResponse.diagnosticsWritten` (this module) has to
/// name the type, and `SnittAutomation` depends on `SnittDocument` only —
/// never `SnittApp`. `DiagnosticsBundle.write(to:auditLogURL:sinceMinutes:)`
/// (`SnittApp`) is still the only thing that constructs one; this is just
/// where the wire shape has to live.
///
/// §12 asks for recent logs, app/CLI versions, permission states, and recent
/// session metadata — nothing more. §5's privacy framing applies just as
/// hard here as it does to capture itself, because this file is meant to be
/// attached to a support thread and read by a stranger: no window titles, no
/// file paths, no keystroke or click detail.
public struct DiagnosticsReport: Codable, Sendable, Equatable {
    public let appVersion: String
    public let protocolVersion: Int
    public let generatedAt: Date
    public let permissions: [String: String]
    public let recentSessions: [AuditRecord]
    public let logLines: [String]

    /// Whether §12's opt-in crash-report collection was ON for this export.
    ///
    /// Load-bearing by itself, independent of `crashReports.isEmpty`: a
    /// reader of this bundle must be able to tell "collection was off" apart
    /// from "collection was on and found nothing to report" — an empty array
    /// alone conflates a machine that has never crashed with a machine whose
    /// operator never opted in. Off by default, same as the setting.
    public let crashReportingEnabled: Bool

    /// Redacted summaries of Snitt's OWN crash reports, gated entirely on
    /// `crashReportingEnabled`. Always `[]` when that is `false`.
    public let crashReports: [CrashReportSummary]

    public init(
        appVersion: String,
        protocolVersion: Int,
        generatedAt: Date,
        permissions: [String: String],
        recentSessions: [AuditRecord],
        logLines: [String],
        crashReportingEnabled: Bool = false,
        crashReports: [CrashReportSummary] = []
    ) {
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.generatedAt = generatedAt
        self.permissions = permissions
        self.recentSessions = recentSessions
        self.logLines = logLines
        self.crashReportingEnabled = crashReportingEnabled
        self.crashReports = crashReports
    }
}

/// One of Snitt's own crash reports
/// (`~/Library/Logs/DiagnosticReports/*.ips`), reduced to fields safe for a
/// support bundle.
///
/// Deliberately narrow, and deliberately has no field for a file path.
/// `CrashReportCollector` (`SnittApp`) is the only thing that ever reads an
/// `.ips` file, and it reads only each file's small JSON HEADER line — never
/// the much larger JSON body that follows, which is where an `.ips` file
/// carries the crashing binary's absolute path and, inside that path, the
/// user's home directory. There is no path-stripping step here because
/// nothing upstream of this type ever extracts one in the first place.
public struct CrashReportSummary: Codable, Sendable, Equatable {
    public let incidentID: String
    public let timestamp: Date
    public let osVersion: String
    public let appVersion: String
    public let bugType: String

    public init(
        incidentID: String,
        timestamp: Date,
        osVersion: String,
        appVersion: String,
        bugType: String
    ) {
        self.incidentID = incidentID
        self.timestamp = timestamp
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.bugType = bugType
    }
}
