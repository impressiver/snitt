// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

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

    /// The most bytes `readHeaderLine` will ever read looking for the
    /// newline that ends an `.ips` header, in bytes. Real header lines
    /// observed in the wild run well under 1 KB; this leaves generous
    /// headroom for a future macOS format while still bounding the search —
    /// a file with no newline at all within this many bytes is treated as
    /// having no parseable header rather than read indefinitely.
    private static let headerReadLimit = 8 * 1024

    /// How many bytes `readHeaderLine` reads at a time while searching for
    /// the header's terminating newline. Small on purpose: reading in small
    /// chunks and stopping as soon as the newline appears in the buffer is
    /// what keeps the body genuinely OUT of the returned `Data` — a single
    /// large read (even one truncated to `headerReadLimit`) would routinely
    /// pull thousands of body bytes in alongside the header, since real
    /// header lines run under 1 KB but 8 KB was chosen as a generous safety
    /// margin, not a tight one.
    private static let headerScanChunkSize = 256

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
                guard let headerLine = readHeaderLine(of: url) else { return nil }
                return parse(headerLine)
            }

        // An unparseable timestamp (`nil`) sorts as though it were the
        // oldest possible report — it must not sort first just because
        // `nil` compares that way by default in some orderings — but the
        // field itself stays `nil` rather than a fabricated date.
        return Array(summaries
            .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
            .prefix(limit))
    }

    /// Reads `url` in `headerScanChunkSize`-byte chunks, stopping the moment
    /// a newline appears in what has been read so far, and returns only the
    /// bytes BEFORE that newline — never the whole file, and never a fixed
    /// prefix either. A single `read(upToCount: headerReadLimit)` (8 KB)
    /// would routinely pull thousands of body bytes in alongside the
    /// header — measured against a real `.ips`, over 6 KB of body,
    /// `procPath` included — because 8 KB is a generous safety margin, not a
    /// tight one. Reading in small chunks and truncating at the newline as
    /// soon as it is found is what keeps the body genuinely out of the
    /// `Data` this returns, not merely unparsed.
    ///
    /// `headerReadLimit` still bounds the total: a file with no newline
    /// within that many bytes stops being read and is treated as having no
    /// parseable header (`parse` will fail closed on it either way).
    static func readHeaderLine(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var buffer = Data()
        while buffer.count < headerReadLimit {
            guard let chunk = try? handle.read(upToCount: headerScanChunkSize), !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)
            if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                return buffer[buffer.startIndex..<newlineIndex]
            }
        }
        // No newline turned up within the bound. `firstLine` still handles
        // a genuinely header-only file (no body follows at all) by treating
        // the whole thing as the header; anything else fails to decode as
        // JSON and `parse` returns `nil`.
        return buffer.isEmpty ? nil : buffer
    }

    /// Parses one `.ips` file's HEADER line — already isolated by
    /// `readHeaderLine`, which never returns any body byte — and returns a
    /// summary iff that header's `bundleID` identifies Snitt's own process.
    ///
    /// `.ips` files are two JSON documents separated by a newline: a small
    /// header, then a much larger body report, which is where the crashing
    /// binary's absolute path (and, inside it, the user's home directory)
    /// lives. `firstLine` below is a second, redundant cut at the same
    /// newline — belt-and-suspenders for any future caller of `parse` that
    /// hands it a buffer `readHeaderLine` did not produce — but the actual
    /// guarantee is made by the read, not by this trim: the body is never
    /// read off disk in the first place, so there is no path-stripping step
    /// to get wrong or forget here.
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
            timestamp: parseTimestamp(header.timestamp),
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
