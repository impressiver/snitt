import Testing
import Foundation
import SnittAutomation
@testable import SnittApp

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("DiagnosticsBundleCrashReportsTests-\(UUID().uuidString)")
}

private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiagnosticsBundleCrashReportsTests-dir-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func writeIPS(in directory: URL, named name: String, bundleID: String?,
                      incidentID: String = UUID().uuidString) throws -> URL {
    var header: [String: Any] = [
        "app_name": "Snitt",
        "timestamp": "2024-01-01 12:00:00.00 -0800",
        "app_version": "1.2.3",
        "os_version": "macOS 14.0 (23A344)",
        "incident_id": incidentID,
        "bug_type": "309",
    ]
    if let bundleID { header["bundleID"] = bundleID }
    let headerData = try JSONSerialization.data(withJSONObject: header)
    let body: [String: Any] = [
        "procPath": "/Users/testuser/Applications/Snitt.app/Contents/MacOS/Snitt",
        "parentPath": "/Users/testuser/Library/CoreServices",
    ]
    let bodyData = try JSONSerialization.data(withJSONObject: body)
    var combined = headerData
    combined.append(UInt8(ascii: "\n"))
    combined.append(bodyData)
    let url = directory.appendingPathComponent(name)
    try combined.write(to: url)
    return url
}

@MainActor
@Test("With crash reporting OFF, an export never reads the crash-report directory's contents")
func crashReportingOffCollectsNothing() throws {
    // §12's opt-in, driven end-to-end through the same `write` the app
    // actually calls: collection must be gated on the setting, not merely
    // possible when a report happens to exist. Verified against the wrong
    // implementation this guards: a `write` that calls
    // `CrashReportCollector.recent` unconditionally (ignoring
    // `crashReportSettings.enabled`) makes this fail — the report would come
    // back non-empty even with the setting off.
    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }
    let crashDir = tempDirectory(); defer { try? FileManager.default.removeItem(at: crashDir) }
    try writeIPS(in: crashDir, named: "Snitt.ips", bundleID: "com.impressiver.snitt")

    let report = try DiagnosticsBundle.write(
        to: out, auditLogURL: auditURL, sinceMinutes: 5,
        crashReportSettings: CrashReportSettings(enabled: false),
        crashReportsDirectory: crashDir)

    #expect(report.crashReportingEnabled == false)
    #expect(report.crashReports.isEmpty,
            "collection must not run at all while the setting is off, even though a report exists on disk")
}

@MainActor
@Test("With crash reporting ON, Snitt's own crash report is folded into the bundle")
func crashReportingOnCollectsOwnReports() throws {
    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }
    let crashDir = tempDirectory(); defer { try? FileManager.default.removeItem(at: crashDir) }
    try writeIPS(in: crashDir, named: "Snitt.ips", bundleID: "com.impressiver.snitt", incidentID: "ABC-1")

    let report = try DiagnosticsBundle.write(
        to: out, auditLogURL: auditURL, sinceMinutes: 5,
        crashReportSettings: CrashReportSettings(enabled: true),
        crashReportsDirectory: crashDir)

    #expect(report.crashReportingEnabled == true)
    #expect(report.crashReports.count == 1)
    #expect(report.crashReports.first?.incidentID == "ABC-1")
}

@MainActor
@Test("A foreign app's crash report never reaches an enabled export")
func crashReportingOnStillExcludesForeignReports() throws {
    // Same trap as `CrashReportCollectorTests.dropsForeignCrashReports`, but
    // exercised through the actual bundle-writing path a user's "on" toggle
    // drives, not just the collector in isolation.
    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }
    let crashDir = tempDirectory(); defer { try? FileManager.default.removeItem(at: crashDir) }
    try writeIPS(in: crashDir, named: "Foreign.ips", bundleID: "com.example.otherapp", incidentID: "FOREIGN-1")

    let report = try DiagnosticsBundle.write(
        to: out, auditLogURL: auditURL, sinceMinutes: 5,
        crashReportSettings: CrashReportSettings(enabled: true),
        crashReportsDirectory: crashDir)

    #expect(report.crashReportingEnabled == true)
    #expect(report.crashReports.isEmpty,
            "a foreign app's crash report must never reach an exported bundle, even with the setting on")
}

@MainActor
@Test("The written bundle states whether crash reporting was on, distinguishing 'off' from 'on, none found'")
func writtenFileStatesCrashReportingStatus() throws {
    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    let crashDir = tempDirectory(); defer { try? FileManager.default.removeItem(at: crashDir) }

    let offOut = tempURL(); defer { try? FileManager.default.removeItem(at: offOut) }
    _ = try DiagnosticsBundle.write(
        to: offOut, auditLogURL: auditURL, sinceMinutes: 5,
        crashReportSettings: CrashReportSettings(enabled: false),
        crashReportsDirectory: crashDir)
    let offWritten = try String(contentsOf: offOut, encoding: .utf8)
    #expect(offWritten.contains("\"crashReportingEnabled\" : false")
         || offWritten.contains("\"crashReportingEnabled\":false"),
            "a reader must be able to tell collection was off from the written file alone")

    let onOut = tempURL(); defer { try? FileManager.default.removeItem(at: onOut) }
    _ = try DiagnosticsBundle.write(
        to: onOut, auditLogURL: auditURL, sinceMinutes: 5,
        crashReportSettings: CrashReportSettings(enabled: true),
        crashReportsDirectory: crashDir)
    let onWritten = try String(contentsOf: onOut, encoding: .utf8)
    #expect(onWritten.contains("\"crashReportingEnabled\" : true")
         || onWritten.contains("\"crashReportingEnabled\":true"),
            "'on, but none found' must be distinguishable from 'off' in the written file")
}

@MainActor
@Test("A crash-report directory that has never been created still exports")
func missingCrashDirectoryStillExports() throws {
    let auditURL = tempURL(); defer { try? FileManager.default.removeItem(at: auditURL) }
    let out = tempURL(); defer { try? FileManager.default.removeItem(at: out) }
    let neverCreated = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiagnosticsBundleCrashReportsTests-never-\(UUID().uuidString)")

    let report = try DiagnosticsBundle.write(
        to: out, auditLogURL: auditURL, sinceMinutes: 5,
        crashReportSettings: CrashReportSettings(enabled: true),
        crashReportsDirectory: neverCreated)

    #expect(report.crashReports.isEmpty)
    #expect(FileManager.default.fileExists(atPath: out.path))
}
