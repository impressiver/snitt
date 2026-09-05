import Foundation
import OSLog
import SnittAutomation
import SnittCapture
import SnittDocument

/// A support bundle: what shipped to `snitt diagnostics export`.
///
/// §12 asks for recent logs, app/CLI versions, permission states, and recent
/// session metadata — nothing more. §5's privacy framing applies just as
/// hard here as it does to capture itself, because this file is meant to be
/// attached to a support thread and read by a stranger: no window titles, no
/// file paths, no keystroke or click detail.
///
/// `os_log` already redacts string-interpolated values unless a call site
/// marks them `.public` — that mark is the actual privacy boundary for this
/// feature. Anything logged `.public` anywhere in Snitt will show up,
/// verbatim, inside a bundle a customer emails to support. Marking an
/// interpolation `.public` is a decision about what leaves the machine, not
/// a debugging convenience.
///
/// `DiagnosticsReport` itself lives in `SnittAutomation`
/// (`AutomationResponse.diagnosticsWritten` has to name it, and that module
/// depends on `SnittDocument` only — never on this one), imported here
/// through the existing `SnittAutomation` import below.
///
/// Assembles and writes a `DiagnosticsReport`.
///
/// This runs in the app, not the CLI. Spike S8 measured that
/// `OSLogStore(scope: .currentProcessIdentifier)` reads back only the
/// calling process's own entries — a CLI-side implementation would bundle
/// the CLI's own handful of log lines and none of the app's, which is the
/// same thin-client rule §4.9 gives capture (there it was TCC; here it is
/// process scope). `snitt diagnostics export` must ask the app for this
/// over the automation socket rather than assembling it locally.
@MainActor
public enum DiagnosticsBundle {
    /// How many of the most recent agent sessions to include. A support
    /// bundle wants recent history, not a machine's full lifetime.
    private static let sessionLimit = 50

    /// Builds a `DiagnosticsReport` and writes it as pretty-printed JSON to
    /// `url`, returning the same report that was written.
    ///
    /// Permission states come from the existing preflight readers
    /// (`ScreenRecordingAccess.isGranted()`, `InputMonitoringAccess.isGranted()`)
    /// and only those — never `ensureGranted()`. A support export runs
    /// unattended or semi-attended and must never raise a system permission
    /// dialog; that would be the worst version of the preflight/request
    /// confusion this project has already hit three times.
    ///
    /// A missing audit log is not a fault: `AuditLog.read` (via
    /// `AuditLog.recent`) returns `[]` for a machine that has never run an
    /// agent session, and that machine must still get a diagnostics bundle.
    public static func write(to url: URL, auditLogURL: URL, sinceMinutes: Int) throws -> DiagnosticsReport {
        let sessions = try AuditLog.recent(sessionLimit, from: auditLogURL)
        let logLines = try recentLogLines(sinceMinutes: sinceMinutes)

        let permissions: [String: String] = [
            "screenRecording": ScreenRecordingAccess.isGranted() ? "granted" : "not granted",
            "inputMonitoring": InputMonitoringAccess.isGranted() ? "granted" : "not granted",
        ]

        let report = DiagnosticsReport(
            appVersion: SnittDocument.version,
            protocolVersion: AutomationProtocol.version,
            generatedAt: Date(),
            permissions: permissions,
            recentSessions: sessions,
            logLines: logLines
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)

        return report
    }

    /// Reads back this process's own `os_log` entries from the last
    /// `sinceMinutes` minutes, keeping only entries whose subsystem is
    /// Snitt's own (or one of its per-target subsystems), formatted as
    /// `"[subsystem/category] message"`.
    ///
    /// `OSLogStore(scope: .currentProcessIdentifier)` needs no entitlement
    /// (S8) but sees only entries logged by the calling process — the
    /// reason this whole type must live in the app.
    private static func recentLogLines(sinceMinutes: Int) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let since = Date().addingTimeInterval(-Double(sinceMinutes) * 60)
        let position = store.position(date: since)

        var lines: [String] = []
        for entry in try store.getEntries(at: position) {
            guard let entry = entry as? OSLogEntryLog,
                  entry.subsystem.hasPrefix(SnittLog.subsystem)
            else { continue }
            lines.append("[\(entry.subsystem)/\(entry.category)] \(entry.composedMessage)")
        }
        return lines
    }
}
