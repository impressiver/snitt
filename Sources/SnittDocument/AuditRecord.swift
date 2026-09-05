import Foundation

/// §12: "Every agent-initiated session is audit-logged — session id, target,
/// duration, initiator, outcome — so an agent-side incident can be
/// reconstructed even though no human watched it happen. This serves §5 as
/// much as it serves support."
///
/// §5.3's whole premise is that agent recordings happen with nobody present;
/// this is how anyone reconstructs what a background process recorded and
/// why.
///
/// A record is written once at session start (`endedAt`/`outcome` nil) and,
/// because the log is append-only JSONL, a session's end is recorded as a
/// *second* record with the same `sessionID` rather than an in-place update
/// — see `AuditLog` below for how readers are expected to reconcile that.
public struct AuditRecord: Codable, Sendable, Equatable {
    public let sessionID: String
    public let target: String
    public let initiator: String
    public let startedAt: Date
    public var endedAt: Date?
    public var outcome: String?

    public init(
        sessionID: String,
        target: String,
        initiator: String,
        startedAt: Date,
        endedAt: Date? = nil,
        outcome: String? = nil
    ) {
        self.sessionID = sessionID
        self.target = target
        self.initiator = initiator
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
    }

    /// Nil while the session is still running. Reporting 0 instead would
    /// read as "finished instantly" in an incident review, indistinguishable
    /// from a session that never got a completion record.
    ///
    /// Deliberately COMPUTED, not stored: `startedAt`/`endedAt` are the one
    /// source of truth, so mutating `endedAt` (as `AuditLog`'s callers and
    /// this type's own tests do) can never leave a stale duration sitting
    /// alongside it. Encoded explicitly below — a computed property is
    /// invisible to `Codable`'s synthesized `encode(to:)`, which is exactly
    /// why every prior export of this record silently had no
    /// `durationSeconds` field even though §12 lists duration among what
    /// the audit must record.
    public var durationSeconds: Double? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, target, initiator, startedAt, endedAt, outcome, durationSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        target = try container.decode(String.self, forKey: .target)
        initiator = try container.decode(String.self, forKey: .initiator)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        outcome = try container.decodeIfPresent(String.self, forKey: .outcome)
        // `durationSeconds` is never decoded: it is derived from
        // `startedAt`/`endedAt` above, and giving it a second, independently
        // decoded source of truth is how it could drift from them.
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(target, forKey: .target)
        try container.encode(initiator, forKey: .initiator)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encodeIfPresent(outcome, forKey: .outcome)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
    }
}

/// An append-only JSONL audit log of agent-initiated recording sessions.
///
/// JSONL, one record per line, appended with a `FileHandle` rather than
/// decode-mutate-rewrite: a single JSON array would need rewriting on every
/// append and would be corrupted by a crash mid-write — precisely when the
/// audit matters most. A truncated final line in JSONL costs one record,
/// not the file.
public enum AuditLog {
    /// Appends `record` as one JSON line, creating the file (and any missing
    /// parent directories) if it does not already exist. Never reads or
    /// rewrites existing content.
    public static func append(_ record: AuditRecord, to url: URL) throws {
        let encoder = JSONEncoder()
        var data = try encoder.encode(record)
        data.append(0x0A) // "\n"

        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            fm.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Reads every decodable record in file order.
    ///
    /// A missing file means no agent session has ever run on this machine —
    /// legitimate, and must not fail a diagnostics export — so it returns
    /// `[]`. A file that exists but cannot be read as UTF-8 text (or any
    /// other I/O fault) is a real fault and throws, rather than reporting
    /// "no agent sessions" for a machine that has run hundreds.
    ///
    /// A line that fails to decode as `AuditRecord` (e.g. a truncated final
    /// line left by a crash mid-append) is skipped; it costs only itself.
    public static func read(from url: URL) throws -> [AuditRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let contents = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate

        var records: [AuditRecord] = []
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let record = try? decoder.decode(AuditRecord.self, from: lineData)
            else {
                continue
            }
            records.append(record)
        }
        return records
    }

    /// The most recent `count` records, oldest-to-newest within that tail —
    /// what a diagnostics bundle wants, not a year of history.
    public static func recent(_ count: Int, from url: URL) throws -> [AuditRecord] {
        let all = try read(from: url)
        guard count < all.count else { return all }
        return Array(all.suffix(count))
    }
}
