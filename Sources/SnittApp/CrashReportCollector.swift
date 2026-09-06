import Foundation
import SnittAutomation
import SnittCapture

/// Reads Snitt's own crash reports out of macOS's on-disk crash-report
/// directory and reduces each to a `CrashReportSummary` safe for a support
/// bundle.
///
/// No signal handler, no in-process crash reporter, no network, no new
/// dependency: macOS already writes a `.ips` file to
/// `~/Library/Logs/DiagnosticReports/` for every crash. An in-process
/// handler runs inside an already-corrupted process — a classic source of
/// crashes inside the crash handler — so this reads what macOS already
/// wrote instead of installing one.
///
/// `~/Library/Logs/DiagnosticReports/` holds crash reports for EVERY
/// application on the machine, not just Snitt's — the user's browser, their
/// password manager, whatever else crashed that week. Sweeping the whole
/// directory into a support bundle would hand a stranger someone else's
/// crash data. Every `.ips` file's own JSON header names the crashing
/// process's bundle identifier; `recent(in:)` reads only entries whose
/// `bundleID` is Snitt's own.
public enum CrashReportCollector {
    /// Must equal `CFBundleIdentifier` (`Scripts/make-app.sh`'s
    /// `BUNDLE_ID`). Reused from `SnittLog.subsystem` rather than a second
    /// literal: the two happen to share a value, and letting them drift
    /// apart would either silently stop collecting Snitt's own crashes or
    /// start collecting someone else's — the exact failure this type exists
    /// to prevent.
    static let bundleIdentifier = SnittLog.subsystem

    /// The real location macOS writes crash reports to. Tests must never use
    /// this — `recent(limit:in:)` takes an explicit `directory` so a test
    /// fixture never touches (or needs) the user's actual crash log
    /// directory.
    public static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// Reads and redacts up to `limit` of Snitt's own crash reports found in
    /// `directory`, most recent first.
    ///
    /// A missing directory (no crash has ever been written, on this machine
    /// or in a test's temp fixture) is not a fault: returns `[]`, same as
    /// `AuditLog.recent` does for a machine with no agent sessions.
    public static func recent(limit: Int = 20, in directory: URL = defaultDirectory()) -> [CrashReportSummary] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        let summaries = entries
            .filter { $0.pathExtension.lowercased() == "ips" }
            .compactMap { url -> CrashReportSummary? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return parse(data)
            }

        return Array(summaries.sorted { $0.timestamp > $1.timestamp }.prefix(limit))
    }

    /// Parses one `.ips` file's HEADER line only, and returns a summary iff
    /// that header's `bundleID` identifies Snitt's own process.
    ///
    /// `.ips` files are two JSON documents separated by a newline: a small
    /// header, then a much larger body report. Only the header is ever
    /// decoded here. The body is where the crashing binary's absolute path
    /// (and, inside it, the user's home directory) lives — this
    /// deliberately never reads far enough to see it, so there is no
    /// path-stripping step to get wrong or forget: the redaction is that the
    /// path is never read in the first place.
    ///
    /// The identity check (`header.bundleID == bundleIdentifier`) is
    /// intentionally on `bundleID`, not on `app_name`/`name` — a display
    /// name is not an identity, and matching on it would let a foreign
    /// report through if some other app happened to also be named "Snitt".
    static func parse(_ data: Data) -> CrashReportSummary? {
        guard let headerLine = firstLine(of: data) else { return nil }
        guard let header = try? JSONDecoder().decode(IPSHeader.self, from: headerLine) else { return nil }
        guard let bundleID = header.bundleID, bundleID == bundleIdentifier else { return nil }

        return CrashReportSummary(
            incidentID: header.incident_id ?? "unknown",
            timestamp: parseTimestamp(header.timestamp) ?? Date(timeIntervalSince1970: 0),
            osVersion: header.os_version ?? "unknown",
            appVersion: header.app_version ?? "unknown",
            bugType: header.bug_type ?? "unknown"
        )
    }

    private static func firstLine(of data: Data) -> Data? {
        if let newlineIndex = data.firstIndex(of: UInt8(ascii: "\n")) {
            return data[data.startIndex..<newlineIndex]
        }
        return data.isEmpty ? nil : data
    }

    /// macOS formats an `.ips` header's `timestamp` like
    /// `"2024-01-01 12:00:00.00 -0800"`.
    private static func parseTimestamp(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return formatter.date(from: string)
    }

    /// The `.ips` header line's shape. Every field is optional because this
    /// is untrusted, externally-written input — a truncated or
    /// future-format header must fail closed (`parse` returns `nil`) rather
    /// than crash the export it is a small part of.
    private struct IPSHeader: Decodable {
        var timestamp: String?
        var app_version: String?
        var bundleID: String?
        var os_version: String?
        var incident_id: String?
        var bug_type: String?
    }
}
