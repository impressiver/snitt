// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// One recognized word, in SOURCE time.
///
/// Source time, not output time, for the same reason waveform samples are:
/// the words are facts about `capture.mov`, and cuts change which of them are
/// audible, not where they were spoken. Mapping to the edited timeline happens
/// at display time through `Timebase`, like everything else.
public struct TranscriptWord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    /// Seconds from the start of the recording.
    public var start: Double
    public var duration: Double
    /// The recognizer's 0...1 confidence. Kept so the UI can render doubt —
    /// D68's own probe read "loom is" at 0.34 for what was probably "Loom is",
    /// and a transcript that hides how sure it is invites trusting the wrong
    /// words.
    public var confidence: Double

    public var end: Double { start + duration }

    public init(id: UUID = UUID(), text: String, start: Double,
                duration: Double, confidence: Double) {
        self.id = id
        self.text = text
        self.start = start
        self.duration = duration
        self.confidence = confidence
    }
}

/// The whole recording's transcript — `transcript.json` in the bundle.
///
/// Its own sidecar rather than rows in `events.json`: an event log is what
/// HAPPENED (clicks, keys, markers), a transcript is what was SAID, they are
/// consulted by different features, and a 10-minute narration is easily a
/// thousand words — bloating every event-log read with them buys nothing.
public struct Transcript: Codable, Equatable, Sendable {
    /// Version-gated like `edit.json` (D60): builds coexist on one machine,
    /// and an old build must refuse a newer file loudly rather than decode
    /// what it recognises and destroy the rest on its next write.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var words: [TranscriptWord]
    /// Which locale the recognizer ran with, so a re-transcription can tell
    /// whether the existing file already answers the question being asked.
    public var locale: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, words, locale
    }

    public init(schemaVersion: Int = Transcript.currentSchemaVersion,
                words: [TranscriptWord], locale: String) {
        self.schemaVersion = schemaVersion
        self.words = words
        self.locale = locale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw TranscriptError.unsupportedSchemaVersion(
                found: schemaVersion, maxSupported: Self.currentSchemaVersion)
        }
        self.schemaVersion = schemaVersion
        self.words = try container.decode([TranscriptWord].self, forKey: .words)
        self.locale = try container.decode(String.self, forKey: .locale)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Always the CURRENT version — the same rule edit.json learned from
        // its own review: a file read as v(N-1) and re-saved carries v(N)
        // content, so it must declare v(N).
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(words, forKey: .words)
        try container.encode(locale, forKey: .locale)
    }

    public static func read(from bundle: SnittBundle) throws -> Transcript {
        let data = try Data(contentsOf: bundle.transcriptURL)
        return try JSONDecoder().decode(Transcript.self, from: data)
    }

    public func write(to bundle: SnittBundle) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: bundle.transcriptURL, options: .atomic)
    }
}

public enum TranscriptError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchemaVersion(found: Int, maxSupported: Int)

    public var description: String {
        switch self {
        case let .unsupportedSchemaVersion(found, maxSupported):
            return "This transcript.json declares schemaVersion \(found), but this build "
                 + "only understands up to \(maxSupported). Refusing to open it: a partial "
                 + "read would silently drop what this build can't represent, and the next "
                 + "save would make that loss permanent. Update Snitt to open this recording."
        }
    }
}
