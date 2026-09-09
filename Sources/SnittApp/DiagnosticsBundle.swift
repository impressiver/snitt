// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import CryptoKit
import Security
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
    /// (`ScreenRecordingAccess.isGranted()`, `InputMonitoringAccess.isGranted()`,
    /// `MicrophoneAccess.isGranted()`) and only those — never `ensureGranted()`.
    /// A support export runs unattended or semi-attended and must never raise
    /// a system permission dialog; that would be the worst version of the
    /// preflight/request confusion this project has already hit three times.
    ///
    /// A missing audit log is not a fault: `AuditLog.read` (via
    /// `AuditLog.recent`) returns `[]` for a machine that has never run an
    /// agent session, and that machine must still get a diagnostics bundle.
    ///
    /// `crashReportSettings`/`crashReportsDirectory` default to the real
    /// setting and the real macOS crash-log directory; tests override both
    /// so no test ever touches the real preference domain or
    /// `~/Library/Logs/DiagnosticReports/`.
    ///
    /// `collectCrashReports` is the actual collection step, injected rather
    /// than called inline, so a test can assert it was never INVOKED when
    /// the setting is off — not merely that its result was discarded. A
    /// read-then-throw-away refactor (read every `.ips` file regardless,
    /// then gate only the assignment) would still be a privacy defect even
    /// though `crashReports` would come out identical; making the read
    /// itself the thing under test is what catches that shape of mistake.
    public static func write(
        to url: URL,
        auditLogURL: URL,
        sinceMinutes: Int,
        crashReportSettings: CrashReportSettings = .load(),
        crashReportsDirectory: URL = CrashReportCollector.defaultDirectory(),
        collectCrashReports: (URL) -> [CrashReportSummary] = { CrashReportCollector.recent(in: $0) }
    ) throws -> DiagnosticsReport {
        let sessions = try AuditLog.recent(sessionLimit, from: auditLogURL)
        let logLines = try recentLogLines(sinceMinutes: sinceMinutes)

        let permissions: [String: String] = [
            "screenRecording": ScreenRecordingAccess.isGranted() ? "granted" : "not granted",
            "inputMonitoring": InputMonitoringAccess.isGranted() ? "granted" : "not granted",
            "microphone": MicrophoneAccess.isGranted() ? "granted" : "not granted",
        ]

        // §12's opt-in: crash reports are collected only when the setting is
        // ON, never merely because some exist on disk. The `collectCrashReports`
        // call itself is inside this branch — not hoisted out and gated only
        // on assignment — so that being off means the collector is never
        // INVOKED, not just that its result goes unused. `crashReports` stays
        // `[]` when it is off — `crashReportingEnabled` below is what lets a
        // reader tell that apart from "on, and none found".
        let crashReports = crashReportSettings.enabled
            ? collectCrashReports(crashReportsDirectory)
            : []

        let report = DiagnosticsReport(
            appVersion: AppVersion.current,
            protocolVersion: AutomationProtocol.version,
            generatedAt: Date(),
            permissions: permissions,
            recentSessions: {
                // One salt for the whole export: targets stay comparable
                // WITHIN a bundle and are not comparable across bundles,
                // which is exactly the scope a support engineer needs.
                let salt = freshSalt()
                return sessions.map { redactingTarget($0, salt: salt) }
            }(),
            logLines: logLines,
            crashReportingEnabled: crashReportSettings.enabled,
            crashReports: crashReports
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // §12 asks for a HUMAN-readable audit trail. Apple-epoch doubles
        // (`"startedAt": 810292682.018656`) are unreadable without doing
        // arithmetic in your head; ISO 8601 is not. `DiagnosticsReport`'s
        // own `generatedAt` and every `AuditRecord.startedAt`/`endedAt`
        // inside `recentSessions` all go through this same encoder, so this
        // one line fixes all of them together.
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)

        return report
    }

    /// Replaces `record.target` (the window/app title `RecordingCoordinator`
    /// stores — e.g. `SCWindow.title`) with a short hash, on the EXPORT path
    /// only.
    ///
    /// §12 mandates "target" in the *local* audit log, and `AuditLog`/the
    /// on-disk JSONL keep the real title unredacted so an operator can read
    /// it in Console or with `snitt inspect` on their own machine. But §5.1's
    /// own worked example of why window-scoping matters is a window titled
    /// "Mail Password Required" — exactly the kind of string this bundle
    /// promises never to carry (see the doc comments on this type and on
    /// `DiagnosticsReport`). A stable, non-reversible hash keeps the field
    /// present (so recurring targets are still recognisable to a support
    /// engineer as "the same one") without naming what was on screen.
    private static func redactingTarget(_ record: AuditRecord, salt: Data) -> AuditRecord {
        var redacted = AuditRecord(
            sessionID: record.sessionID,
            target: hashedTarget(record.target, salt: salt),
            initiator: record.initiator,
            startedAt: record.startedAt
        )
        redacted.endedAt = record.endedAt
        redacted.outcome = record.outcome
        return redacted
    }

    /// A short, stable, non-reversible stand-in for a window/app title:
    /// hex of `SHA256(target)`, truncated. Truncated because nothing reads
    /// this by eye for its entropy — only to see whether two sessions in the
    /// same bundle targeted the same window — and a full 64-character digest
    /// would just be more noise in a file a human has to read.
    ///
    /// SALTED PER EXPORT, and that is the load-bearing part. An unsalted
    /// digest is reversible by guessing: anyone holding the bundle can hash
    /// a title they suspect and check for a match, and §5.1's own worked
    /// example — a window titled "Mail Password Required" — is exactly the
    /// kind of string someone would try. A fresh random salt per export
    /// keeps the only property this field is FOR (two sessions in one
    /// bundle sharing a target look alike) while making a guess
    /// unverifiable. The salt is never written to the file, so it dies with
    /// the export.
    private static func hashedTarget(_ target: String, salt: Data) -> String {
        var input = salt
        input.append(Data(target.utf8))
        let digest = SHA256.hash(data: input)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "target-" + hex.prefix(12)
    }

    /// 32 random bytes, generated once per `write` and discarded with it.
    private static func freshSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
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
