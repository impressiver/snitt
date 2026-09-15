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
    /// The voice this line belongs to — every word in it, because a paragraph
    /// never mixes two.
    public let track: String

    /// Non-public so `words` cannot be empty: `id` reads `words[0]`.
    fileprivate init(words: [TranscriptWord]) {
        self.id = words[0].id
        self.words = words
        self.track = words[0].track
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
    /// `breakSeconds` long — and never across two voices.
    ///
    /// ONE VOICE PER LINE. The recogniser emits a single stream ordered by
    /// time, so a narrator talking over recorded speech produced lines that
    /// alternated between them word by word: "so and here that we fails". The
    /// pane coloured each word to say which was which, which is a legend for a
    /// sentence nobody can read rather than a fix.
    ///
    /// Each voice is paragraphed on its OWN pauses and the lines are merged
    /// afterwards, so "so here we" stays one line even though another voice
    /// was speaking in the gaps between its words. Splitting on a track change
    /// instead would give one line per word exactly when the two overlap most,
    /// which is worse than the wall of words this replaces.
    ///
    /// Merged by start time, so the lines still read down the recording in the
    /// order things were said.
    public static func split(_ words: [TranscriptWord],
                             breakingAfter breakSeconds: Double = breakSeconds)
        -> [TranscriptParagraph] {
        let voices = AudibleTranscript.voices(words)
        // One voice is the overwhelmingly common case and must be untouched by
        // any of this: no merge, no re-sort, the same lines it always gave.
        guard voices.count > 1 else {
            return voices.first.map { paragraph($0.words, breakingAfter: breakSeconds) } ?? []
        }
        return voices
            .flatMap { paragraph($0.words, breakingAfter: breakSeconds) }
            .sorted { $0.words[0].start < $1.words[0].start }
    }

    /// The pause-splitting itself, run once per voice.
    private static func paragraph(_ words: [TranscriptWord],
                                  breakingAfter breakSeconds: Double)
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

    /// Where a paragraph sits on the OUTPUT timeline, or nil when every word
    /// in it has been cut away.
    ///
    /// Output, not source, because this is a number a person reads next to the
    /// transport's own clock and next to the marker rail's timestamps. A
    /// source time would be right about the recording and wrong about the
    /// edit, and it would stop agreeing with the playhead the moment anything
    /// was trimmed — which is most of the time this app is open.
    ///
    /// The FIRST SURVIVING word, not simply the first. Cut words stay on
    /// screen struck through (that is what `TranscriptPane` draws and what
    /// `split` is fed), so a paragraph can begin with words that have no
    /// position in the output at all. Asking `trimmedTime` about one of those
    /// gets nil, and a paragraph that is half kept would then have no
    /// timestamp despite being perfectly reachable.
    ///
    /// Nil is reserved for the case that actually has no answer: every word
    /// gone. The pane shows no time there, which is the truth — there is
    /// nowhere to click to.
    public static func outputStart(of paragraph: TranscriptParagraph,
                                   keptRanges: [TimeRange]) -> Double? {
        for word in paragraph.words {
            if let trimmed = TimeRangeMapping.trimmedTime(of: word.start,
                                                          keptRanges: keptRanges) {
                return trimmed
            }
        }
        return nil
    }
}
