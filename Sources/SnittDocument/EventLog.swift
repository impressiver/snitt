import Foundation

public enum EventKind: String, Codable, Sendable {
    case click
    case keystroke
    case marker
}

/// One timestamped entry in the sidecar log. Times are seconds from the start
/// of the recording. Events are data, never drawn into the video (spec 4.5).
///
/// `id` and `transcript` were added by M5f Task 6 (D56/D50): a marker needed
/// an address a drag or an edit could name — `LoggedEvent` had none, exactly
/// the gap `Cut` closed for cuts in Task 2 — and a place to hold the
/// narration text D50 defines, exported as WebVTT by a later milestone (M5e).
/// Custom `Codable` below, not synthesis, so a `LoggedEvent` written before
/// this task (no `id` key at all) still decodes: `Cut.init(from:)` set the
/// precedent of minting a fresh `UUID` per missing id rather than refusing to
/// read the file or — worse — reusing one sentinel id for every event in it,
/// which would make every legacy marker in one bundle indistinguishable from
/// every other.
public struct LoggedEvent: Sendable {
    public var id: UUID
    public var timeSeconds: Double
    public var kind: EventKind
    public var label: String?
    /// A marker's narration text (D50) — `nil` for non-marker events, and
    /// for a marker that has none yet. Distinct from `label`: `label` is the
    /// marker's short name (jump-point list, WebVTT chapter title today);
    /// `transcript` is the longer text a later milestone (M5e) burns into
    /// WebVTT subtitles. This task only adds the field and lets the editor
    /// read/write it — the WebVTT export path is out of scope here (see
    /// `WebVTTChapters`, untouched).
    public var transcript: String?

    public init(id: UUID = UUID(), timeSeconds: Double, kind: EventKind,
                label: String? = nil, transcript: String? = nil) {
        self.id = id
        self.timeSeconds = timeSeconds
        self.kind = kind
        self.label = label
        self.transcript = transcript
    }
}

/// `Identifiable` is the Swift standard library's, not AppKit's or
/// SwiftUI's — this module stays AppKit-free. Added for `SnittApp`'s marker
/// edit sheet (`.sheet(item:)`, M5f Task 6), which needs a stable identity
/// to bind to; `id` already exists for exactly that purpose.
extension LoggedEvent: Identifiable {}

extension LoggedEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, timeSeconds, kind, label, transcript
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Legacy (pre-M5f-Task-6) events carry no `id` key at all — mint one
        // rather than failing to decode, so an events.json written before
        // this task still opens (mirrors `Cut.init(from:)`).
        let id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let timeSeconds = try container.decode(Double.self, forKey: .timeSeconds)
        let kind = try container.decode(EventKind.self, forKey: .kind)
        let label = try container.decodeIfPresent(String.self, forKey: .label)
        let transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
        self.init(id: id, timeSeconds: timeSeconds, kind: kind, label: label, transcript: transcript)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timeSeconds, forKey: .timeSeconds)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(transcript, forKey: .transcript)
    }
}

/// The sidecar `events.json` this project's spec (§7) treats as a distinct
/// document from `edit.json` — a different file, with its own
/// `schemaVersion`. Unlike `EditDecisionList`'s (D60), this one is NOT
/// enforced: `read(from:)` never compares it, so a newer build's added
/// fields (like `LoggedEvent.id`/`transcript`, M5f Task 6) simply decode as
/// `nil`/minted for an older build that doesn't know them, rather than
/// refusing the file outright. `edit.json` got exactly that enforcement from
/// D60, for the same hand-delivered-updates reason (D54) that applies here
/// too — deliberately left open by this task rather than solved incidentally
/// alongside markers: it deserves its own decision, not a side effect of an
/// unrelated field addition.
public struct EventLog: Codable, Sendable {
    /// Bumped 1 -> 2 by M5f Task 6: `LoggedEvent` gained `id` and
    /// `transcript`. Informational only (see this type's own doc comment) —
    /// nothing refuses a mismatched value on read.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var events: [LoggedEvent]

    public init(schemaVersion: Int = EventLog.currentSchemaVersion, events: [LoggedEvent] = []) {
        self.schemaVersion = schemaVersion
        self.events = events
    }

    public func write(to bundle: SnittBundle) throws {
        try JSONCoding.encoder.encode(self).write(to: bundle.eventsURL)
    }

    public static func read(from bundle: SnittBundle) throws -> EventLog {
        try decode(from: Data(contentsOf: bundle.eventsURL))
    }

    /// Decodes a standalone `events.json` payload, for callers (and tests)
    /// that already have the bytes rather than a bundle — the events-side
    /// twin of `EditDecisionList.decode(from:)`.
    public static func decode(from data: Data) throws -> EventLog {
        try JSONCoding.decoder.decode(EventLog.self, from: data)
    }
}
