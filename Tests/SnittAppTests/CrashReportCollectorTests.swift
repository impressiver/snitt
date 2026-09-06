import Testing
import Foundation
@testable import SnittApp

private func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CrashReportCollectorTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a fixture `.ips` file: a JSON header line, a newline, then a JSON
/// body — the real on-disk shape macOS writes to
/// `~/Library/Logs/DiagnosticReports/`. `procPath`/`parentPath` in the body
/// stand in for the real fields that carry the crashing binary's absolute
/// path and the user's home directory, which is why every fixture below
/// plants one: a fixture with no path in it could not catch a redaction
/// that forgot to omit one.
@discardableResult
private func writeIPS(
    in directory: URL,
    named name: String,
    bundleID: String?,
    appName: String = "Snitt",
    incidentID: String = UUID().uuidString,
    timestamp: String = "2024-01-01 12:00:00.00 -0800",
    osVersion: String = "macOS 14.0 (23A344)",
    appVersion: String = "1.2.3",
    bugType: String = "309",
    procPath: String = "/Users/testuser/Applications/Snitt.app/Contents/MacOS/Snitt"
) throws -> URL {
    var header: [String: Any] = [
        "app_name": appName,
        "timestamp": timestamp,
        "app_version": appVersion,
        "os_version": osVersion,
        "incident_id": incidentID,
        "bug_type": bugType,
    ]
    if let bundleID { header["bundleID"] = bundleID }
    let headerData = try JSONSerialization.data(withJSONObject: header)

    let body: [String: Any] = [
        "procPath": procPath,
        "parentPath": "/Users/testuser/Library/CoreServices",
        "exception": ["type": "EXC_CRASH"],
    ]
    let bodyData = try JSONSerialization.data(withJSONObject: body)

    var combined = headerData
    combined.append(UInt8(ascii: "\n"))
    combined.append(bodyData)

    let url = directory.appendingPathComponent(name)
    try combined.write(to: url)
    return url
}

@Test("A directory holding only Snitt's own crash report is collected")
func collectsSnittsOwnCrashReport() throws {
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    try writeIPS(in: dir, named: "Snitt-2024-01-01-120000.ips",
                bundleID: "com.impressiver.snitt", incidentID: "AAA-111")

    let reports = CrashReportCollector.recent(in: dir)

    #expect(reports.count == 1)
    #expect(reports.first?.incidentID == "AAA-111")
}

@Test("A foreign app's crash report, even one that also NAMES itself Snitt, is dropped")
func dropsForeignCrashReportsEvenWhenNamedSnitt() throws {
    // The trap this whole feature exists to avoid:
    // `~/Library/Logs/DiagnosticReports/` holds every app's crashes, not
    // just Snitt's. A fixture containing only Snitt reports cannot exercise
    // the filter at all — this one plants a foreign report ALONGSIDE
    // Snitt's own and asserts only the latter survives.
    //
    // `writeIPS`'s `appName` defaults to `"Snitt"` and is not overridden
    // here, so the foreign fixture below is foreign by `bundleID` alone
    // while still claiming the display name "Snitt" — the same shape
    // `dropsCrashReportsThatOnlyShareTheDisplayName` targets directly. That
    // makes this test strictly STRONGER than "two differently-named apps",
    // not weaker: it is named for what actually distinguishes it from that
    // sibling test.
    //
    // Verified against the wrong implementation this guards: relaxing
    // `parse`'s `bundleID == bundleIdentifier` check to `true` (accept
    // everything) makes this fail — both reports come back instead of one.
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    try writeIPS(in: dir, named: "Snitt-2024-01-01-120000.ips",
                bundleID: "com.impressiver.snitt", incidentID: "OURS-1")
    try writeIPS(in: dir, named: "SomeBrowser-2024-01-01-130000.ips",
                bundleID: "com.example.browser", incidentID: "FOREIGN-1",
                procPath: "/Users/testuser/Applications/SomeBrowser.app/Contents/MacOS/SomeBrowser")

    let reports = CrashReportCollector.recent(in: dir)

    #expect(reports.count == 1, "exactly one of the two on-disk reports is Snitt's own")
    #expect(reports.first?.incidentID == "OURS-1")
    #expect(!reports.contains { $0.incidentID == "FOREIGN-1" })
}

@Test("An ordinarily-named foreign app's crash report is dropped alongside Snitt's own")
func dropsOrdinarilyNamedForeignCrashReports() throws {
    // The plain case `dropsForeignCrashReportsEvenWhenNamedSnitt` no longer
    // covers once its fixture's foreign report also claimed the "Snitt"
    // display name: a foreign report that names itself honestly, the
    // ordinary shape a real browser or password manager's crash takes.
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    try writeIPS(in: dir, named: "Snitt-2024-01-01-120000.ips",
                bundleID: "com.impressiver.snitt", incidentID: "OURS-2")
    try writeIPS(in: dir, named: "SomeBrowser-2024-01-01-130000.ips",
                bundleID: "com.example.browser", appName: "SomeBrowser", incidentID: "FOREIGN-2",
                procPath: "/Users/testuser/Applications/SomeBrowser.app/Contents/MacOS/SomeBrowser")

    let reports = CrashReportCollector.recent(in: dir)

    #expect(reports.count == 1)
    #expect(reports.first?.incidentID == "OURS-2")
}

@Test("A foreign report that merely NAMES itself Snitt is still dropped")
func dropsCrashReportsThatOnlyShareTheDisplayName() throws {
    // Identity is `bundleID`, not `app_name`/`name` — a display name can
    // collide (or be spoofed by a differently-identified process); a bundle
    // identifier can't, by construction. This fixture's `app_name` is
    // "Snitt" but its `bundleID` is a different app entirely, so a filter
    // that matched on name instead of identity would wrongly let it
    // through.
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    try writeIPS(in: dir, named: "NotActuallySnitt.ips",
                bundleID: "com.impostor.snitt", appName: "Snitt", incidentID: "IMPOSTOR-1")

    let reports = CrashReportCollector.recent(in: dir)

    #expect(reports.isEmpty, "matching on name instead of bundle identity would wrongly include this")
}

@Test("A crash report with no bundleID at all is dropped, not treated as ours")
func dropsCrashReportsMissingBundleID() throws {
    // Failing OPEN here (treating "no identity present" as "assume it's
    // ours") would be the same shape of mistake as accepting everything.
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    try writeIPS(in: dir, named: "NoBundleID.ips", bundleID: nil, incidentID: "NOBID-1")

    let reports = CrashReportCollector.recent(in: dir)

    #expect(reports.isEmpty)
}

@Test("The collected summary never carries the crashing binary's path or the user's home directory")
func summaryOmitsPathsEntirely() throws {
    // `.ips`'s body carries `procPath`/`parentPath` with the user's home
    // directory embedded in them. This asserts the redaction holds not just
    // on the struct's known fields but on its full ENCODED form — the
    // artefact that actually leaves the machine inside a diagnostics
    // bundle — so a future field added to `CrashReportSummary` that
    // accidentally captures a path would still be caught here.
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    try writeIPS(in: dir, named: "Snitt.ips", bundleID: "com.impressiver.snitt",
                procPath: "/Users/testuser/Applications/Snitt.app/Contents/MacOS/Snitt")

    let reports = CrashReportCollector.recent(in: dir)
    #expect(reports.count == 1)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let encoded = String(data: try encoder.encode(reports), encoding: .utf8) ?? ""

    #expect(!encoded.contains("testuser"), "the username embedded in the crash path must never appear")
    #expect(!encoded.contains("/Users/"), "no absolute path may appear in a collected summary")
    #expect(!encoded.contains("procPath"))
}

@Test("A directory that does not exist yields no crash reports, not an error")
func missingDirectoryYieldsNoReports() {
    // Mirrors `AuditLog.recent`'s handling of a machine that has never run
    // an agent session (`DiagnosticsBundleTests.noSessionsStillExports`): a
    // machine that has never crashed must still get a diagnostics bundle.
    let neverCreated = FileManager.default.temporaryDirectory
        .appendingPathComponent("CrashReportCollectorTests-never-\(UUID().uuidString)")
    #expect(CrashReportCollector.recent(in: neverCreated).isEmpty)
}

@Test("A malformed .ips file is skipped rather than aborting the whole collection")
func malformedFileIsSkipped() throws {
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    try Data("not json at all".utf8).write(to: dir.appendingPathComponent("garbage.ips"))
    try writeIPS(in: dir, named: "Snitt.ips", bundleID: "com.impressiver.snitt", incidentID: "GOOD-1")

    let reports = CrashReportCollector.recent(in: dir)

    #expect(reports.count == 1)
    #expect(reports.first?.incidentID == "GOOD-1")
}

@Test("A non-.ips file in the directory is ignored")
func nonIPSFilesAreIgnored() throws {
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    try Data("hello".utf8).write(to: dir.appendingPathComponent("readme.txt"))
    try writeIPS(in: dir, named: "Snitt.ips", bundleID: "com.impressiver.snitt", incidentID: "GOOD-1")

    let reports = CrashReportCollector.recent(in: dir)

    #expect(reports.count == 1)
}

@Test("The header's timestamp, OS version, app version and bug type all survive into the summary")
func summaryCarriesHeaderFields() throws {
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    try writeIPS(in: dir, named: "Snitt.ips", bundleID: "com.impressiver.snitt",
                timestamp: "2024-03-15 09:30:00.00 -0700",
                osVersion: "macOS 14.4 (23E214)", appVersion: "2.0.0", bugType: "309")

    let report = try #require(CrashReportCollector.recent(in: dir).first)

    #expect(report.osVersion == "macOS 14.4 (23E214)")
    #expect(report.appVersion == "2.0.0")
    #expect(report.bugType == "309")
    // 2024-03-15 09:30:00 -0700 == 2024-03-15T16:30:00Z
    let timestamp = try #require(report.timestamp)
    #expect(abs(timestamp.timeIntervalSince1970 - 1_710_520_200) < 1)
}

@Test("An unparseable header timestamp becomes nil, not a fabricated epoch date")
func unparseableTimestampBecomesNilNotEpoch() throws {
    // A wrong implementation that falls back to `Date(timeIntervalSince1970: 0)`
    // puts "1970-01-01T00:00:00Z" into a support bundle, which a reader
    // would take as a real (absurd) date rather than as "not parsed", and
    // which would sort ahead of every genuinely old-but-parsed report at the
    // wrong end. The sibling `String` fields (`osVersion`, `appVersion`,
    // `bugType`) all fall back to the literal `"unknown"` instead of a
    // fabricated value in the same situation — `timestamp` must fail the
    // same way, as `nil`, not as a date.
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    try writeIPS(in: dir, named: "Snitt.ips", bundleID: "com.impressiver.snitt",
                timestamp: "not a real timestamp")

    let report = try #require(CrashReportCollector.recent(in: dir).first)

    #expect(report.timestamp == nil)
}

@Test("Reports are returned most-recent first")
func reportsAreSortedMostRecentFirst() throws {
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    try writeIPS(in: dir, named: "old.ips", bundleID: "com.impressiver.snitt",
                incidentID: "OLD", timestamp: "2023-01-01 00:00:00.00 -0800")
    try writeIPS(in: dir, named: "new.ips", bundleID: "com.impressiver.snitt",
                incidentID: "NEW", timestamp: "2024-06-01 00:00:00.00 -0700")

    let reports = CrashReportCollector.recent(in: dir)

    #expect(reports.map(\.incidentID) == ["NEW", "OLD"])
}

@Test("recent(limit:) never returns more than the requested limit")
func recentRespectsLimit() throws {
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    for index in 0..<5 {
        try writeIPS(in: dir, named: "s\(index).ips", bundleID: "com.impressiver.snitt",
                    incidentID: "R\(index)",
                    timestamp: "2024-01-0\(index + 1) 00:00:00.00 -0800")
    }

    #expect(CrashReportCollector.recent(limit: 2, in: dir).count == 2)
}

@Test("readHeaderLine returns exactly the header line, never the file's body — the read is genuinely bounded, not merely the parse")
func readHeaderLineNeverReadsTheBody() throws {
    // Pins the fix for the finding that `parse`'s comment once overstated:
    // a single `handle.read(upToCount: 8192)` (the code's own prior shape)
    // still pulls thousands of body bytes in alongside the header for a
    // real `.ips` — measured at over 6 KB, `procPath` included — so
    // asserting on PARSED OUTPUT alone (as every other test in this file
    // does) cannot see that gap: the filter and the redaction both still
    // behave correctly either way. This asserts on what was actually READ
    // off disk instead.
    //
    // Verified against both wrong implementations this guards: reverting to
    // `try? Data(contentsOf: url)` (the whole file, 200 KB+ here) and
    // reverting to a single bounded `read(upToCount: headerReadLimit)`
    // (8 KB) each make this fail — the returned `Data` is far larger than
    // the header line alone in both cases.
    let dir = tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let header: [String: Any] = [
        "app_name": "Snitt",
        "timestamp": "2024-01-01 12:00:00.00 -0800",
        "app_version": "1.2.3",
        "os_version": "macOS 14.0 (23A344)",
        "incident_id": "BOUND-1",
        "bug_type": "309",
        "bundleID": "com.impressiver.snitt",
    ]
    let headerData = try JSONSerialization.data(withJSONObject: header)

    var combined = headerData
    combined.append(UInt8(ascii: "\n"))
    // Far larger than any read bound this file has ever used, so a revert
    // to reading the whole file (or even a single generous fixed-size read)
    // returns something conspicuously bigger than the header alone.
    combined.append(Data(repeating: UInt8(ascii: "A"), count: 200_000))

    let url = dir.appendingPathComponent("Big.ips")
    try combined.write(to: url)

    let headerLine = try #require(CrashReportCollector.readHeaderLine(of: url))

    #expect(headerLine.count == headerData.count,
            "must return exactly the header line's bytes, not the file's body")
    #expect(headerLine.count < 2048,
            "a read that pulled in any meaningful slice of the 200 KB body would not be genuinely bounded")

    // And the file is still usable end to end: the collector reads the
    // actual header out of it correctly despite the enormous body.
    let reports = CrashReportCollector.recent(in: dir)
    #expect(reports.first?.incidentID == "BOUND-1")
}
