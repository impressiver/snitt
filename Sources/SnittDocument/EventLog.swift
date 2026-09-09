// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

public enum EventKind: String, Codable, Sendable {
    case click
    case keystroke
    case marker
    /// Where the pointer was, with no click. Reported, never observed: the
    /// `CGEventTap` mask deliberately excludes `mouseMoved` because it fires
    /// continuously, so this kind exists for automation that knows where it
    /// "moved" without anything having moved.
    case cursor
}

/// Whether Snitt saw an event happen or was told it happened.
///
/// Browser automation dispatches events into the page — `element.click()`,
/// CDP's `Input.dispatchMouseEvent` — and the OS cursor never moves. Nothing
/// reaches the event tap, so a recording of automated work shows things
/// changing with no visible cause, which is exactly what makes an agent demo
/// unwatchable. An agent can instead REPORT what it did.
///
/// Reported events are marked, and that is not bookkeeping. `autoTrimRange`
/// treats every non-marker event as evidence of activity and
/// `InspectReport.inputEventCount` publishes a count; without provenance,
/// "a person clicked here" and "an automation asserts it clicked here" become
/// the same claim, and a recording could vouch for input that never happened.
public enum EventSource: String, Codable, Sendable {
    /// Seen by the `CGEventTap` — a real event the OS delivered.
    case observed
    /// Supplied by a client over the automation API.
    case reported
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
    /// Where in the recorded window this happened, as fractions of the
    /// window's own bounds (0...1, origin top-left).
    ///
    /// Normalized rather than screen coordinates because those would need the
    /// window's frame AT THAT INSTANT to be meaningful, and Snitt keeps no
    /// window-position track (D64 names one as a prerequisite for visible
    /// clicks and it does not exist). A fraction of the window is exact
    /// forever, survives the window being moved or resized afterwards, and
    /// multiplies straight into video coordinates at any export scale.
    public var x: Double?
    public var y: Double?
    /// Whether Snitt saw this or was told about it. Defaults to `observed`, so
    /// every event written before this field existed reads correctly.
    public var source: EventSource

    public init(id: UUID = UUID(), timeSeconds: Double, kind: EventKind,
                label: String? = nil, transcript: String? = nil,
                x: Double? = nil, y: Double? = nil,
                source: EventSource = .observed) {
        self.id = id
        self.timeSeconds = timeSeconds
        self.kind = kind
        self.label = label
        self.transcript = transcript
        self.x = x
        self.y = y
        self.source = source
    }
}

/// `Identifiable` is the Swift standard library's, not AppKit's or
/// SwiftUI's — this module stays AppKit-free. Added for `SnittApp`'s marker
/// edit sheet (`.sheet(item:)`, M5f Task 6), which needs a stable identity
/// to bind to; `id` already exists for exactly that purpose.
extension LoggedEvent: Identifiable {}

extension LoggedEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, timeSeconds, kind, label, transcript, x, y, source
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
        let x = try container.decodeIfPresent(Double.self, forKey: .x)
        let y = try container.decodeIfPresent(Double.self, forKey: .y)
        // Absent means OBSERVED: every event written before provenance existed
        // came from the tap, so the default is the historically true answer
        // rather than a neutral one.
        let source = try container.decodeIfPresent(EventSource.self, forKey: .source) ?? .observed
        self.init(id: id, timeSeconds: timeSeconds, kind: kind, label: label,
                  transcript: transcript, x: x, y: y, source: source)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timeSeconds, forKey: .timeSeconds)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(transcript, forKey: .transcript)
        try container.encodeIfPresent(x, forKey: .x)
        try container.encodeIfPresent(y, forKey: .y)
        // Written only when it is NOT the default, so an ordinary human
        // recording's events.json is unchanged by this field existing.
        if source != .observed { try container.encode(source, forKey: .source) }
    }
}

/// Thrown by `EventLog` decoding — the `events.json` twin of
/// `EditDecisionListError` (D60).
///
/// Task 6 bumped `EventLog.currentSchemaVersion` 1 -> 2 (`LoggedEvent` gained
/// `id` and `transcript`) without adding this guard — the same D60 scenario
/// `EditDecisionList` was already enforcing for `edit.json`, left open in a
/// second file. Updates are hand-delivered (D54), so an old and a new Snitt
/// build coexisting on one machine is not hypothetical: without this check,
/// an old build's `Codable` conformance would decode ONLY the fields it
/// recognizes from a newer `events.json` and silently drop the rest —
/// `transcript` included, the only place a marker's narration lives — and
/// the very next write would make that loss permanent. A loud refusal here
/// is the alternative to that silent, unrecoverable loss.
public enum EventLogError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchemaVersion(found: Int, maxSupported: Int)

    public var description: String {
        switch self {
        case let .unsupportedSchemaVersion(found, maxSupported):
            return "This events.json declares schemaVersion \(found), but this build of "
                 + "Snitt only understands up to \(maxSupported). Refusing to open it: "
                 + "a partial read would silently drop marker narration this build can't "
                 + "represent, and the next write would make that loss permanent. Update "
                 + "Snitt to open this recording."
        }
    }
}

/// The sidecar `events.json` this project's spec (§7) treats as a distinct
/// document from `edit.json` — a different file, with its own
/// `schemaVersion`, now enforced exactly the way `EditDecisionList` enforces
/// its own (D60): `init(from:)` checks `schemaVersion` before decoding
/// `events` at all, and refuses outright rather than partially decoding a
/// version above what this build understands.
public struct EventLog: Codable, Sendable {
    /// Bumped 1 -> 2 by M5f Task 6: `LoggedEvent` gained `id` and
    /// `transcript`. A version ABOVE this one is refused by `init(from:)`
    /// rather than partially decoded (`EventLogError`).
    /// Bumped 2 -> 3 for reported input (position + provenance). Non-additive
    /// in the way D60 cares about: an older build decodes an event, drops `x`,
    /// `y` and `source` it has no fields for, and the next write loses them —
    /// so a reported click silently becomes an observed one with no position.
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var events: [LoggedEvent]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, events
    }

    public init(schemaVersion: Int = EventLog.currentSchemaVersion, events: [LoggedEvent] = []) {
        self.schemaVersion = schemaVersion
        self.events = events
    }

    /// Custom rather than synthesized so `schemaVersion` can be checked
    /// BEFORE `events` is decoded at all — the same gate
    /// `EditDecisionList.init(from:)` applies for `edit.json` (D60).
    /// `encode(to:)` is left to synthesis: nothing about writing needs the
    /// same gate.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw EventLogError.unsupportedSchemaVersion(
                found: schemaVersion, maxSupported: Self.currentSchemaVersion)
        }
        self.schemaVersion = schemaVersion
        self.events = try container.decode([LoggedEvent].self, forKey: .events)
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
