// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Narration somebody WRITES, rather than narration the recogniser hears.
///
/// The input half of speech synthesis (D101): you stand at a moment in the
/// recording, type what should be said there, and it becomes a phrase on the
/// voiceover track. Today that phrase is captioned and read; once synthesis
/// exists it is also the script that gets spoken.
///
/// It earns its keep before synthesis arrives. A screencast whose narration is
/// written rather than recorded still gets subtitles, still gets a transcript
/// to edit, and still shows the narration lane in the timeline — and writing
/// beats re-recording a take to fix one sentence.
public enum AuthoredNarration {

    /// How fast the words are assumed to be spoken.
    ///
    /// `SpeechRate`'s, which the captions and the sidecar also read. A second
    /// constant here would let an authored line be captioned for a length its
    /// own text was never measured against.
    public static var wordsPerSecond: Double { SpeechRate.wordsPerSecond }

    /// `text` as transcript words, starting at `sourceStart`.
    ///
    /// Each word gets an equal share, because nothing here knows any better.
    /// Per-word timings rather than one long word: every surface downstream —
    /// the caption grouper, the phrase chips, the playhead's current-word
    /// highlight — is built on words, and a phrase pretending to be one would
    /// be a single 4-second "word" that highlights all at once and can never
    /// be split by a cut.
    ///
    /// Empty or whitespace-only text yields nothing. A blank line is not a
    /// thing to place on the timeline, and refusing it here means no caller
    /// has to decide what an empty phrase means.
    public static func words(_ text: String, sourceStart: Double,
                             track: String = "voiceover") -> [TranscriptWord] {
        let pieces = text.split(whereSeparator: \.isWhitespace).map(String.init)
        // No `!pieces.isEmpty` guard: mapping an empty array already returns
        // an empty array, so it was a branch that could not change the answer.
        // The mutation gate found it by deleting it and nothing failing —
        // `blankTextYieldsNothing` still holds, because the behaviour it
        // asserts comes from the map rather than from the guard.
        guard wordsPerSecond > 0 else { return [] }
        let each = 1 / wordsPerSecond
        return pieces.enumerated().map { index, piece in
            TranscriptWord(text: piece,
                           start: sourceStart + Double(index) * each,
                           duration: each,
                           // A human wrote it, so the recogniser's doubt does
                           // not apply — the same reasoning `correctWord` uses
                           // for a word somebody has just retyped.
                           confidence: 1.0,
                           track: track,
                           isAuthored: true)
        }
    }

    /// `words` merged into `existing`, in time order.
    ///
    /// Sorted by start, because every consumer of a transcript assumes it —
    /// `TranscriptParagraphs` walks it looking for pauses, and a phrase
    /// appended at the end but anchored at the beginning would read as one
    /// enormous gap followed by a line out of sequence.
    ///
    /// Stable within a start time: an authored phrase placed at the exact
    /// moment of a spoken word must not reorder the speech around it.
    public static func inserting(_ words: [TranscriptWord],
                                 into existing: [TranscriptWord]) -> [TranscriptWord] {
        guard !words.isEmpty else { return existing }
        return (existing + words).enumerated()
            .sorted { left, right in
                left.element.start == right.element.start
                    ? left.offset < right.offset
                    : left.element.start < right.element.start
            }
            .map(\.element)
    }
}
