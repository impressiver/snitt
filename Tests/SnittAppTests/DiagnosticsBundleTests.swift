import Testing
import Foundation
import OSLog
import SnittDocument
import SnittCapture
import SnittAutomation
@testable import SnittApp

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("DiagnosticsBundleTests-\(UUID().uuidString)")
}

/// A directory that is never created, passed to every `DiagnosticsBundle.write`
/// call in this file alongside `CrashReportSettings(enabled: false)` below.
///
/// None of these tests are about crash reporting, so isolation from the real
/// `~/Library/Logs/DiagnosticReports/` must be structural, not ambient: a
/// `write` call here that omitted both overrides would fall through to
/// `CrashReportSettings.load()` (the real `UserDefaults.standard`) and
/// `CrashReportCollector.defaultDirectory()` (the real crash-log directory),
/// and would happen to be safe only because the key is absent on the machine
/// running the suite.
private func neverCreatedCrashDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("DiagnosticsBundleTests-crashreports-\(UUID().uuidString)")
}

@MainActor
@Test("The report carries versions, permissions and recent sessions")
func reportHasTheSpecifiedSections() throws {
    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    try AuditLog.append(AuditRecord(sessionID: "S1", target: "Safari", initiator: "agent",
                                    startedAt: Date()), to: auditURL)
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }

    let report = try DiagnosticsBundle.write(to: out, auditLogURL: auditURL, sinceMinutes: 5,
        crashReportSettings: CrashReportSettings(enabled: false),
        crashReportsDirectory: neverCreatedCrashDirectory())

    #expect(!report.appVersion.isEmpty)
    #expect(report.protocolVersion > 0)
    #expect(report.recentSessions.count == 1)
    #expect(report.recentSessions[0].sessionID == "S1")
    #expect(!report.permissions.isEmpty)
    #expect(FileManager.default.fileExists(atPath: out.path))
}

@MainActor
@Test("The export carries a finished session's duration, and human-readable dates")
func exportCarriesDurationAndReadableDates() throws {
    // §12 lists duration among what the audit must record, but
    // `AuditRecord.durationSeconds` was a COMPUTED property — invisible to
    // `Codable`'s synthesized `encode(to:)` — so no exported record ever
    // carried one, and nothing but a dedicated unit test on the struct
    // itself ever noticed. This drives the actual export path
    // (`DiagnosticsBundle.write`), not `AuditRecord` in isolation, so it
    // catches the same gap `snitt diagnostics export` would ship with.
    let started = Date(timeIntervalSince1970: 1_700_000_000)
    let ended = started.addingTimeInterval(42)
    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    try AuditLog.append(AuditRecord(sessionID: "S1", target: "Safari", initiator: "agent",
                                    startedAt: started), to: auditURL)
    try AuditLog.append(AuditRecord(sessionID: "S1", target: "Safari", initiator: "agent",
                                    startedAt: started, endedAt: ended, outcome: "completed"),
                        to: auditURL)
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }

    let report = try DiagnosticsBundle.write(to: out, auditLogURL: auditURL, sinceMinutes: 5,
        crashReportSettings: CrashReportSettings(enabled: false),
        crashReportsDirectory: neverCreatedCrashDirectory())

    let finished = try #require(report.recentSessions.last { $0.outcome == "completed" })
    #expect(finished.durationSeconds == 42)

    let written = try String(contentsOf: out, encoding: .utf8)
    // The WRITTEN file, not just the in-memory report: this is the artefact
    // an implementation could still get wrong (e.g. an encoder that
    // round-trips `durationSeconds` through the model but never actually
    // configures the file-writing encoder to include it).
    #expect(written.contains("\"durationSeconds\""),
            "a finished session's duration must appear in the exported file")
    // A raw Apple-epoch double (e.g. "810292682.018656") is not human
    // readable; a support engineer reads this file directly. ISO 8601
    // dates contain a literal "T" separating date and time and end in "Z".
    #expect(!written.contains("1700000042") && !written.contains("1.7e"),
            "dates must not be encoded as raw epoch numbers")
    #expect(written.contains("2023-11-14T22:14:02Z") || written.range(
        of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"#, options: .regularExpression) != nil,
            "dates must be encoded as ISO 8601, e.g. 2023-11-14T22:13:20Z")
}

@MainActor
@Test("The bundle captures log lines this process just wrote")
func bundleCapturesOurOwnLogs() throws {
    let marker = UUID().uuidString
    SnittLog.logger(.automation, target: "SnittApp")
        .error("diagnostics probe \(marker, privacy: .public)")

    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }
    let report = try DiagnosticsBundle.write(to: out, auditLogURL: auditURL, sinceMinutes: 5,
        crashReportSettings: CrashReportSettings(enabled: false),
        crashReportsDirectory: neverCreatedCrashDirectory())

    // The discriminating assertion. An implementation that writes versions
    // and permissions but no logs passes every other test here, and is
    // exactly the "looks like it works, contains nothing useful" outcome
    // S8 warns about.
    #expect(report.logLines.contains { $0.contains(marker) })
}

@MainActor
@Test("A support bundle excludes foreign-subsystem log lines while keeping Snitt's own")
func bundleExcludesForeignSubsystemLogs() throws {
    // `DiagnosticsBundle.recentLogLines`'s subsystem filter
    // (`entry.subsystem.hasPrefix(SnittLog.subsystem)`) is the only thing
    // standing between a customer's exported bundle and every AVFoundation,
    // ScreenCaptureKit and networking framework log line on the system —
    // full of URLs and file paths of their own. The reviewer mutated that
    // one line to `true` and 110 tests still passed, because nothing here
    // ever logged through a subsystem other than Snitt's own: every
    // existing test, including `bundleCapturesOurOwnLogs` above, only
    // proves inclusion, never exclusion.
    let ours = UUID().uuidString
    let foreign = UUID().uuidString
    SnittLog.logger(.automation, target: "SnittApp")
        .error("ours \(ours, privacy: .public)")
    // A subsystem Snitt does not own and would never emit — standing in for
    // AVFoundation/ScreenCaptureKit/etc, which the app has no control over
    // and which routinely logs paths and URLs `.public`.
    Logger(subsystem: "com.apple.avfoundation.stand-in", category: "probe")
        .error("foreign \(foreign, privacy: .public)")

    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }
    let report = try DiagnosticsBundle.write(to: out, auditLogURL: auditURL, sinceMinutes: 5,
        crashReportSettings: CrashReportSettings(enabled: false),
        crashReportsDirectory: neverCreatedCrashDirectory())

    #expect(report.logLines.contains { $0.contains(ours) },
            "Snitt's own log lines must still reach the bundle")
    #expect(!report.logLines.contains { $0.contains(foreign) },
            "a foreign subsystem's log lines must never reach a support bundle")
}

@MainActor
@Test("A machine with no agent sessions still exports")
func noSessionsStillExports() throws {
    let auditURL = tempURL()   // never created
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }
    // Support bundles are requested most often by people who have never run
    // an agent session. Failing here would deny diagnostics to exactly the
    // users most likely to need them.
    let report = try DiagnosticsBundle.write(to: out, auditLogURL: auditURL, sinceMinutes: 5,
        crashReportSettings: CrashReportSettings(enabled: false),
        crashReportsDirectory: neverCreatedCrashDirectory())
    #expect(report.recentSessions.isEmpty)
    #expect(FileManager.default.fileExists(atPath: out.path))
}

@MainActor
@Test("The written file is the report, and parses back")
func writtenFileParsesBack() throws {
    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }
    let report = try DiagnosticsBundle.write(to: out, auditLogURL: auditURL, sinceMinutes: 5,
        crashReportSettings: CrashReportSettings(enabled: false),
        crashReportsDirectory: neverCreatedCrashDirectory())

    // A support engineer has to read this. A file that exists but is not
    // parseable is a worse outcome than no file, because it looks like
    // evidence.
    //
    // `.iso8601` matches `DiagnosticsBundle.write`'s own encoder: dates in
    // the file are human-readable text ("2023-11-14T22:13:20Z"), not raw
    // Apple-epoch doubles, so a decoder must be told the same strategy the
    // encoder used.
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(DiagnosticsReport.self,
                                     from: Data(contentsOf: out))
    #expect(decoded.appVersion == report.appVersion)
    #expect(decoded.recentSessions.count == report.recentSessions.count)
}

@MainActor
@Test("A support bundle never carries a session's raw window title")
func bundleRedactsSessionTargets() throws {
    // `AuditRecord.target` is `RecordingCoordinator`'s SCWindow.title — §5.1's
    // own worked example of why this matters is a window titled "Mail
    // Password Required". §12 wants "target" in the LOCAL audit log, and
    // `AuditLog` (the on-disk JSONL) is right to keep it unredacted for the
    // operator — but this file is the one attached to public support
    // threads, and both `DiagnosticsReport`'s doc comment and the
    // `snitt_diagnostics_export` MCP description promise "no window
    // titles". This pins that promise against the export path specifically.
    let title = "Mail Password Required"
    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    try AuditLog.append(AuditRecord(sessionID: "S1", target: title, initiator: "agent",
                                    startedAt: Date()), to: auditURL)
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }

    let report = try DiagnosticsBundle.write(to: out, auditLogURL: auditURL, sinceMinutes: 5,
        crashReportSettings: CrashReportSettings(enabled: false),
        crashReportsDirectory: neverCreatedCrashDirectory())

    // The redaction must survive to the WRITTEN file, not just the in-memory
    // report — the file is the artefact that leaves the machine.
    let written = try String(contentsOf: out, encoding: .utf8)
    #expect(!written.contains(title),
            "a session's window title must not reach an exported support bundle")
    #expect(!report.recentSessions.contains { $0.target == title })

    // The LOCAL audit log is untouched: an operator reading it on their own
    // machine still sees the real title. §12 mandates "target" there, and
    // that mandate is about the local trail, not the export.
    let localRecords = try AuditLog.read(from: auditURL)
    #expect(localRecords.first?.target == title,
            "redaction must apply only to the export, never to the local audit log")

    // The field must still be present and non-empty post-redaction — an
    // implementation that blanks it out entirely also satisfies "no window
    // titles" but throws away the ability to tell two sessions' targets
    // apart, which a support engineer still wants.
    #expect(!(report.recentSessions.first?.target.isEmpty ?? true))
}

@MainActor
@Test("A support bundle carries no recording filename")
func bundleOmitsRecordingFilenames() throws {
    // §5: this file gets attached to support threads. BundleNaming derives a
    // recording's filename from the git branch and commit, so a branch named
    // for a customer or an unreleased feature is exactly the kind of thing
    // that must not travel. `os_log` redacts interpolations by default, but
    // `.public` is what people reach for when a message looks unhelpfully
    // redacted — and one call site had already done so.
    //
    // This asserts on the WRITTEN FILE rather than the report struct,
    // because the file is the artefact that leaves the machine.
    let sentinel = "feat-acme-secret-\(UUID().uuidString.prefix(8))"
    SnittLog.logger(.compositor, target: "SnittApp")
        .error("probe with \(sentinel, privacy: .private)")

    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }
    _ = try DiagnosticsBundle.write(to: out, auditLogURL: auditURL, sinceMinutes: 5,
        crashReportSettings: CrashReportSettings(enabled: false),
        crashReportsDirectory: neverCreatedCrashDirectory())

    let written = try String(contentsOf: out, encoding: .utf8)
    #expect(!written.contains(sentinel),
            "a value logged as .private must not reach an exported support bundle")
}

@MainActor
@Test("A failed audit append's path never reaches a support bundle")
func bundleOmitsErrorFilePaths() async throws {
    // The second route to the leak that redacting a filename did not close,
    // and the one that actually shipped: `AutomationHost.appendAudit`'s catch
    // block logged a caught error with `String(describing:)`, which on a
    // Cocoa NSError serialises userInfo — carrying NSFilePath/NSURL, the full
    // absolute path, so the machine's username and the branch-derived bundle
    // name would travel even though the message itself names no file.
    //
    // Unlike the version of this test that shipped with the leak, THIS ONE
    // DRIVES PRODUCTION CODE: it does not log the error itself "the safe
    // way" inside the test body (that version passed even while the real
    // `appendAudit` catch block was still leaking, because it never called
    // `appendAudit` at all). Instead it makes a real `AutomationHost` fail a
    // real audit append, through the same `AutomationRequest.Body
    // .startRecording` path a client actually sends, and inspects the
    // WRITTEN bundle — the artefact that leaves the machine.
    //
    // Verified against the pre-fix code: restoring
    // `String(describing: error)` at `AutomationHost.appendAudit` makes this
    // fail (the sentinel directory name shows up in the exported bundle);
    // the domain+code fix makes it pass again.
    let sentinel = "feat-acme-secret-\(UUID().uuidString.prefix(8))"
    // A read-only parent directory reproduces the reviewer's "unwritable
    // audit path": `AuditLog.append`'s `createFile` silently fails (it
    // returns `Bool`, never throws), so the throw actually comes from
    // `FileHandle(forWritingTo:)` finding no file — "The file “audit.jsonl”
    // doesn’t exist.", a FIXED, harmless message — while the error's
    // userInfo still carries the real, secret-bearing directory via
    // NSFilePath. That split (safe localizedDescription, unsafe
    // description) is exactly what makes this test able to tell the two
    // fixes apart: a `String(describing:)` catch block leaks the sentinel
    // here even though its own human-readable message never would.
    let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(sentinel)
    try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blocker.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocker.path)
        try? FileManager.default.removeItem(at: blocker)
    }
    let auditLogURL = blocker.appendingPathComponent("audit.jsonl")

    let coordinator = FakeCoordinator()
    let host = AutomationHost(
        coordinator: coordinator,
        settings: { AgentSettings(agentRecordingEnabled: true, fullDisplayAllowed: false) },
        auditLogURL: auditLogURL)

    // `appendAudit` must never fail the recording it describes (see its doc
    // comment): a session that recorded successfully but could not be
    // audited must still report `.started`.
    let started = await host.handle(.startRecording(StartOptions(bundleIdentifier: "com.example.App")))
    guard case .started = started else {
        Issue.record("expected a started response despite the audit append failing, got \(started)")
        return
    }

    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }
    _ = try DiagnosticsBundle.write(to: out, auditLogURL: auditLogURL, sinceMinutes: 5,
        crashReportSettings: CrashReportSettings(enabled: false),
        crashReportsDirectory: neverCreatedCrashDirectory())

    let written = try String(contentsOf: out, encoding: .utf8)
    #expect(!written.contains(sentinel),
            "a failed audit append's file path must not reach an exported support bundle")
    // And the diagnosis survives: domain and code identify the fault exactly.
    #expect(written.contains("NSCocoaErrorDomain"))
}

@MainActor
@Test("Target hashes are comparable within one export and not across exports")
func targetHashesAreSaltedPerExport() throws {
    // Two properties in tension, and the salt's scope is what balances them.
    //
    // WITHIN a bundle the hash must stay comparable, because that is the
    // only thing this field is for once the title is gone: a support
    // engineer seeing that two sessions targeted the same window.
    //
    // ACROSS bundles it must NOT be, because an unsalted digest is
    // reversible by guessing -- anyone holding the file can hash a title
    // they suspect and check for a match, and §5.1's own example is a
    // window titled "Mail Password Required".
    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    let started = Date()
    for id in ["S1", "S2"] {
        try AuditLog.append(AuditRecord(sessionID: id, target: "Mail Password Required",
                                        initiator: "agent", startedAt: started), to: auditURL)
    }

    let outA = tempURL(); defer { try? FileManager.default.removeItem(at: outA) }
    let outB = tempURL(); defer { try? FileManager.default.removeItem(at: outB) }
    let a = try DiagnosticsBundle.write(to: outA, auditLogURL: auditURL, sinceMinutes: 5,
        crashReportSettings: CrashReportSettings(enabled: false),
        crashReportsDirectory: neverCreatedCrashDirectory())
    let b = try DiagnosticsBundle.write(to: outB, auditLogURL: auditURL, sinceMinutes: 5,
        crashReportSettings: CrashReportSettings(enabled: false),
        crashReportsDirectory: neverCreatedCrashDirectory())

    let targetsA = a.recentSessions.map(\.target)
    #expect(targetsA.count == 2)
    #expect(targetsA[0] == targetsA[1], "one export must keep identical targets comparable")
    #expect(!targetsA[0].contains("Mail"), "the title itself must never appear")

    // The discriminating half: an unsalted implementation produces the same
    // digest in every bundle, so this passes only with a per-export salt.
    #expect(targetsA[0] != b.recentSessions[0].target,
            "a target hash must not be reproducible in another export")
}
