// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// A run of words drawn as one chip on the transcript lane.
public struct TranscriptPhrase: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let words: [TranscriptWord]
    /// SOURCE time, like every other fact about words. The lane maps to output
    /// at draw time, the way markers and folds already do.
    public var start: Double { words[0].start }
    public var end: Double { words[words.count - 1].end }
    public var text: String { words.map(\.text).joined(separator: " ") }

    fileprivate init(words: [TranscriptWord]) {
        self.id = words[0].id
        self.words = words
    }
}

/// Grouping words into the chips the transcript lane draws (D89, phrase tier).
///
/// `WordLaneTiers` established that individual word chips are a deep-zoom
/// feature — 0.6pt per word on a ten-minute recording, against the 40pt a chip
/// needs to be read or clicked. Phrases are the tier that works at ordinary
/// zoom, and they are not a compromise: a phrase is what someone actually
/// wants to jump to.
///
/// **The break rule is `TranscriptParagraphs`', not a second one.** The
/// reading pane already decides where the speaker stopped talking, and two
/// answers to "where does a phrase end" would put the lane and the prose out
/// of step — a chip boundary that no paragraph break agrees with is a chip
/// nobody can find in the text.
public enum TranscriptPhrases {

    /// The longest a chip may be before it is split for display.
    ///
    /// A paragraph is bounded by a pause, not by length, so a fluent speaker
    /// produces one forty words long. That is a legitimate paragraph and an
    /// illegible chip: the text is truncated to whatever the chip's width
    /// allows, so past a certain length every chip reads as the same
    /// first-three-words-then-ellipsis and stops distinguishing anything.
    public static let maximumWordsPerPhrase = 8

    public static func phrases(from words: [TranscriptWord],
                               maximumWords: Int = maximumWordsPerPhrase) -> [TranscriptPhrase] {
        guard maximumWords > 0 else { return [] }
        return TranscriptParagraphs.split(words).flatMap { paragraph in
            stride(from: 0, to: paragraph.words.count, by: maximumWords).map { start in
                let end = min(start + maximumWords, paragraph.words.count)
                return TranscriptPhrase(words: Array(paragraph.words[start..<end]))
            }
        }
    }

    /// As much of a phrase as fits, with an ellipsis when it does not.
    ///
    /// Truncation happens here rather than in the drawing code because "what
    /// does this chip say" is a decision, and the answer at a given width
    /// should be assertable without a graphics context.
    public static func displayText(_ phrase: TranscriptPhrase,
                                   widthPoints: Double,
                                   pointsPerCharacter: Double = 6.5) -> String {
        let text = phrase.text
        guard widthPoints > 0, pointsPerCharacter > 0 else { return "" }
        // Two characters of padding either side, and one for the ellipsis.
        let capacity = Int(widthPoints / pointsPerCharacter) - 2
        guard capacity > 1 else { return "" }
        guard text.count > capacity else { return text }
        // A chip too narrow for even one word says nothing rather than an
        // ellipsis on its own, which is chrome pretending to be content.
        let cut = text.prefix(capacity - 1).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? "" : cut + "…"
    }
}
