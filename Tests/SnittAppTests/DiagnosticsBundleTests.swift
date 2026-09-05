import Testing
import Foundation
import SnittDocument
import SnittCapture
@testable import SnittApp

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("DiagnosticsBundleTests-\(UUID().uuidString)")
}

@MainActor
@Test("The report carries versions, permissions and recent sessions")
func reportHasTheSpecifiedSections() throws {
    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    try AuditLog.append(AuditRecord(sessionID: "S1", target: "Safari", initiator: "agent",
                                    startedAt: Date()), to: auditURL)
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }

    let report = try DiagnosticsBundle.write(to: out, auditLogURL: auditURL, sinceMinutes: 5)

    #expect(!report.appVersion.isEmpty)
    #expect(report.protocolVersion > 0)
    #expect(report.recentSessions.count == 1)
    #expect(report.recentSessions[0].sessionID == "S1")
    #expect(!report.permissions.isEmpty)
    #expect(FileManager.default.fileExists(atPath: out.path))
}

@MainActor
@Test("The bundle captures log lines this process just wrote")
func bundleCapturesOurOwnLogs() throws {
    let marker = UUID().uuidString
    SnittLog.logger(.automation, target: "SnittApp")
        .error("diagnostics probe \(marker, privacy: .public)")

    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }
    let report = try DiagnosticsBundle.write(to: out, auditLogURL: auditURL, sinceMinutes: 5)

    // The discriminating assertion. An implementation that writes versions
    // and permissions but no logs passes every other test here, and is
    // exactly the "looks like it works, contains nothing useful" outcome
    // S8 warns about.
    #expect(report.logLines.contains { $0.contains(marker) })
}

@MainActor
@Test("A machine with no agent sessions still exports")
func noSessionsStillExports() throws {
    let auditURL = tempURL()   // never created
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }
    // Support bundles are requested most often by people who have never run
    // an agent session. Failing here would deny diagnostics to exactly the
    // users most likely to need them.
    let report = try DiagnosticsBundle.write(to: out, auditLogURL: auditURL, sinceMinutes: 5)
    #expect(report.recentSessions.isEmpty)
    #expect(FileManager.default.fileExists(atPath: out.path))
}

@MainActor
@Test("The written file is the report, and parses back")
func writtenFileParsesBack() throws {
    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }
    let report = try DiagnosticsBundle.write(to: out, auditLogURL: auditURL, sinceMinutes: 5)

    // A support engineer has to read this. A file that exists but is not
    // parseable is a worse outcome than no file, because it looks like
    // evidence.
    let decoded = try JSONDecoder().decode(DiagnosticsReport.self,
                                           from: Data(contentsOf: out))
    #expect(decoded.appVersion == report.appVersion)
    #expect(decoded.recentSessions.count == report.recentSessions.count)
}
