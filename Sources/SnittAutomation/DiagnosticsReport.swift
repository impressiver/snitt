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

    public init(
        appVersion: String,
        protocolVersion: Int,
        generatedAt: Date,
        permissions: [String: String],
        recentSessions: [AuditRecord],
        logLines: [String]
    ) {
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.generatedAt = generatedAt
        self.permissions = permissions
        self.recentSessions = recentSessions
        self.logLines = logLines
    }
}
