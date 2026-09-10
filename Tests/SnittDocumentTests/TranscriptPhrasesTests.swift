// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// Grouping words into the chips the transcript lane draws.
@Suite
struct TranscriptPhrasesTests {
    private static func word(_ text: String, _ start: Double, _ duration: Double = 0.25) -> TranscriptWord {
        TranscriptWord(text: text, start: start, duration: duration, confidence: 0.9)
    }

    /// Two sentences separated by a real pause, the first of them long.
    ///
    /// STORED, not computed. `TranscriptWord` mints a fresh `UUID` per
    /// instance, so a computed property hands every caller a different set of
    /// identities — and a test comparing words across two accesses of it
    /// compares two different transcripts. Two of these tests failed exactly
    /// that way before this was a `let`.
    private let narration: [TranscriptWord] = {
        var words: [TranscriptWord] = []
        let first = ["okay", "so", "the", "bug", "is", "in", "the", "word", "lookup", "here"]
        for (index, text) in first.enumerated() {
            words.append(Self.word(text, Double(index) * 0.3))
        }
        // A 1.2s gap — past TranscriptParagraphs' 0.6s break.
        let second = ["one", "tick", "of", "tolerance", "fixes", "it"]
        for (index, text) in second.enumerated() {
            words.append(Self.word(text, 4.5 + Double(index) * 0.3))
        }
        return words
    }()

    @Test("Phrases break where the reading pane breaks")
    func breaksMatchTheReadingPane() {
        // One rule for "where did the speaker stop", not two. A chip boundary
        // that no paragraph break agrees with is a chip nobody can find in the
        // prose beside it.
        let phrases = TranscriptPhrases.phrases(from: narration)
        let paragraphs = TranscriptParagraphs.split(narration)
        // Every paragraph's first word must also start a phrase.
        for paragraph in paragraphs {
            #expect(phrases.contains { $0.words[0].id == paragraph.words[0].id },
                    "a paragraph break did not also start a phrase")
        }
    }

    @Test("A long paragraph is split so its chips stay distinguishable")
    func longParagraphsAreSubdivided() {
        // A paragraph is bounded by a pause, not by length, so a fluent
        // speaker produces one forty words long. That is a legitimate
        // paragraph and an illegible chip — truncated, every such chip reads
        // as the same first-three-words-and-an-ellipsis.
        let phrases = TranscriptPhrases.phrases(from: narration, maximumWords: 4)
        #expect(phrases.allSatisfy { $0.words.count <= 4 })
        // The ten-word first sentence becomes three chips, not one.
        #expect(phrases.count == 5)
    }

    @Test("Every word survives grouping, exactly once and in order")
    func groupingLosesNothing() {
        // The concatenation guard. A stride that dropped its last partial
        // chunk would lose the tail of every long paragraph — silently, and
        // only on long paragraphs.
        let phrases = TranscriptPhrases.phrases(from: narration, maximumWords: 3)
        #expect(phrases.flatMap(\.words) == narration)
    }

    @Test("A phrase spans from its first word's start to its last word's end")
    func phraseSpansItsWords() {
        // What the lane positions the chip by. Using the first word's end, or
        // the last word's start, puts the chip somewhere the words are not.
        let phrases = TranscriptPhrases.phrases(from: narration, maximumWords: 4)
        let first = phrases[0]
        #expect(first.start == narration[0].start)
        #expect(abs(first.end - narration[3].end) < 0.001)
    }

    @Test("Text that fits is shown whole")
    func shortTextIsNotTruncated() {
        let phrase = TranscriptPhrases.phrases(from: [Self.word("hello", 0)])[0]
        #expect(TranscriptPhrases.displayText(phrase, widthPoints: 200) == "hello")
    }

    @Test("Text that does not fit is truncated with an ellipsis")
    func longTextIsTruncated() {
        let phrases = TranscriptPhrases.phrases(from: narration, maximumWords: 8)
        let text = TranscriptPhrases.displayText(phrases[0], widthPoints: 60)
        #expect(text.hasSuffix("…"))
        #expect(text.count < phrases[0].text.count)
    }

    @Test("A chip too narrow for a word says nothing, not just an ellipsis")
    func tinyChipIsEmpty() {
        // An ellipsis alone is chrome pretending to be content: it occupies a
        // chip, reads as text, and carries none.
        let phrases = TranscriptPhrases.phrases(from: narration)
        #expect(TranscriptPhrases.displayText(phrases[0], widthPoints: 8) == "")
        #expect(TranscriptPhrases.displayText(phrases[0], widthPoints: 0) == "")
    }

    @Test("An empty transcript produces no phrases rather than one empty chip")
    func emptyTranscriptIsEmpty() {
        #expect(TranscriptPhrases.phrases(from: []).isEmpty)
    }

    @Test("A nonsense maximum produces nothing rather than looping forever")
    func zeroMaximumIsSafe() {
        // `stride(from:to:by:)` with a zero step traps at runtime, so this is
        // a crash guard rather than a tidiness one.
        #expect(TranscriptPhrases.phrases(from: narration, maximumWords: 0).isEmpty)
    }
}
