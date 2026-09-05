import Testing
import Foundation
import SnittDocument
import SnittCapture
import SnittAutomation
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
    _ = try DiagnosticsBundle.write(to: out, auditLogURL: auditURL, sinceMinutes: 5)

    let written = try String(contentsOf: out, encoding: .utf8)
    #expect(!written.contains(sentinel),
            "a value logged as .private must not reach an exported support bundle")
}

@MainActor
@Test("A file error's path never reaches a support bundle")
func bundleOmitsErrorFilePaths() throws {
    // The second route to the leak that redacting a filename did not close.
    // `String(describing:)` on a Cocoa NSError serialises userInfo, which
    // carries NSFilePath and NSURL — the full absolute path, so the machine's
    // username and the branch-derived bundle name travel inside the ERROR
    // even when the message itself names no file.
    //
    // Measured on this toolchain:
    //   describing:  …UserInfo={NSFilePath=/Users/…/feat-acme-…/edit.json, NSURL=…}
    //   localized:   The file “edit.json” couldn’t be opened because…
    let secretPath = "/Users/someone/work/feat-acme-secret-\(UUID().uuidString.prefix(6))/edit.json"
    var caught: Error?
    do { _ = try Data(contentsOf: URL(fileURLWithPath: secretPath)) } catch { caught = error }
    let error = try #require(caught)
    let ns = error as NSError

    // Log it the way production now does.
    SnittLog.logger(.compositor, target: "SnittApp")
        .error("probe: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .public)")

    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }
    _ = try DiagnosticsBundle.write(to: out, auditLogURL: auditURL, sinceMinutes: 5)

    let written = try String(contentsOf: out, encoding: .utf8)
    #expect(!written.contains("feat-acme-secret"),
            "an error's file path must not reach an exported support bundle")
    // And the diagnosis survives: domain and code identify the fault exactly.
    #expect(written.contains("NSCocoaErrorDomain"))
}
