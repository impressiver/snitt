// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// A run of words with no long pause in it — one line of the transcript.
public struct TranscriptParagraph: Equatable, Sendable, Identifiable {
    /// The first word's id.
    ///
    /// Identity has to survive an edit: deleting a word re-splits the whole
    /// transcript, and a `ForEach` keyed on array position would then reuse
    /// the view for paragraph 3 to draw what is now paragraph 4 — the
    /// selection highlight and the inline edit field follow the view, not the
    /// word, so they would land on the wrong words. A word id is already
    /// unique and already stable.
    public let id: UUID
    public let words: [TranscriptWord]

    /// Non-public so `words` cannot be empty: `id` reads `words[0]`.
    fileprivate init(words: [TranscriptWord]) {
        self.id = words[0].id
        self.words = words
    }
}

/// Where the transcript breaks into lines.
///
/// A wall of words is what a recognizer emits and not what anyone reads. The
/// speaker already marked the structure — they stopped talking — and those
/// pauses are in the transcript as gaps between one word's end and the next
/// word's start. This turns them back into line breaks.
///
/// SOURCE time, like everything else about words. Cut words stay on screen
/// struck through, so the sequence being laid out IS the source sequence;
/// grouping on output time would close up around a cut and join two beats the
/// reader can still see are separate.
public enum TranscriptParagraphs {
    /// The pause that ends a line.
    ///
    /// Within a phrase, gaps between words are tens of milliseconds; at a
    /// clause boundary, a few hundred; between one thought and the next — the
    /// beat where a narrator clicks something and then says what they did —
    /// most of a second or more. 0.6s sits above the clause boundary and below
    /// the thought boundary, so a line is a thing someone said in one breath.
    ///
    /// Erring low would be worse than erring high: too small a value shreds
    /// one sentence across four lines, which is harder to read than the wall
    /// of words this replaces, while too large a value simply breaks less
    /// often.
    public static let breakSeconds = 0.6

    /// Splits `words` wherever the silence before a word is at least
    /// `breakSeconds` long.
    public static func split(_ words: [TranscriptWord],
                             breakingAfter breakSeconds: Double = breakSeconds)
        -> [TranscriptParagraph] {
        var paragraphs: [TranscriptParagraph] = []
        var current: [TranscriptWord] = []
        for word in words {
            // From the previous word's END, not its start — a slowly spoken
            // three-second word is not a pause, and measuring start-to-start
            // would break the line after every long one.
            if let previous = current.last, word.start - previous.end >= breakSeconds {
                paragraphs.append(TranscriptParagraph(words: current))
                current = []
            }
            current.append(word)
        }
        if !current.isEmpty { paragraphs.append(TranscriptParagraph(words: current)) }
        return paragraphs
    }
}
