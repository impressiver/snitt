// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// Breaking the transcript into lines at the speaker's pauses.
@Suite
struct TranscriptParagraphsTests {
    private static func word(_ text: String, _ start: Double, _ duration: Double) -> TranscriptWord {
        TranscriptWord(text: text, start: start, duration: duration, confidence: 0.9)
    }

    @Test("A long pause starts a new line")
    func longPauseBreaks() {
        // The whole point. An implementation that never splits returns one
        // paragraph here, which is the behaviour being replaced.
        let words = [Self.word("go", 0.0, 0.3), Self.word("to", 0.3, 0.2),
                     Self.word("let's", 2.0, 0.3), Self.word("find", 2.3, 0.3)]
        let paragraphs = TranscriptParagraphs.split(words)
        #expect(paragraphs.count == 2)
        #expect(paragraphs.first?.words.map(\.text) == ["go", "to"])
        #expect(paragraphs.last?.words.map(\.text) == ["let's", "find"])
    }

    @Test("Normal spacing between words stays on one line")
    func normalSpacingDoesNotBreak() {
        // The opposite failure, and the more damaging one: splitting on every
        // gap shreds a sentence into one word per line. Gaps here are 20-50ms,
        // which is ordinary connected speech.
        let words = [Self.word("let's", 0.0, 0.30), Self.word("play", 0.35, 0.25),
                     Self.word("this", 0.62, 0.20), Self.word("one", 0.84, 0.25)]
        #expect(TranscriptParagraphs.split(words).count == 1)
    }

    @Test("The pause is measured from the previous word's END")
    func gapMeasuredFromEnd() {
        // A slowly spoken long word is not a pause. Measuring start-to-start
        // is the plausible wrong implementation — it reads naturally and
        // passes both tests above — and it breaks the line after every word
        // longer than the threshold. Here the gap is 0.1s but the words are
        // 1.5s apart start to start.
        let words = [Self.word("Sooooundcloud", 0.0, 1.4), Self.word("now", 1.5, 0.3)]
        #expect(TranscriptParagraphs.split(words).count == 1,
                "the line broke after a long word rather than after a pause")
    }

    @Test("Every word survives the split, exactly once and in order")
    func splitLosesNothing() {
        // A concatenation guard. Forgetting the trailing append silently drops
        // the last line — the tests above would still pass if the FINAL
        // paragraph were dropped in a two-paragraph input only by luck of
        // which one they inspect, and a three-break input makes it certain.
        let words = [Self.word("a", 0.0, 0.2), Self.word("b", 1.0, 0.2),
                     Self.word("c", 2.0, 0.2), Self.word("d", 2.3, 0.2), Self.word("e", 4.0, 0.2)]
        let paragraphs = TranscriptParagraphs.split(words)
        #expect(paragraphs.count == 4)
        #expect(paragraphs.flatMap(\.words) == words)
    }

    @Test("A gap exactly at the threshold breaks")
    func thresholdIsInclusive() {
        // Pins the boundary rule rather than leaving it to whichever
        // comparison got typed. Exercised through the parameter so the test
        // does not silently follow a change to the shipped default.
        let words = [Self.word("one", 0.0, 0.5), Self.word("two", 1.1, 0.5)]
        #expect(TranscriptParagraphs.split(words, breakingAfter: 0.6).count == 2)
        #expect(TranscriptParagraphs.split(words, breakingAfter: 0.61).count == 1)
    }

    @Test("Paragraph identity is the first word, not the position")
    func identityIsStable() {
        // SwiftUI reuses views by id. Keying on array position means deleting
        // a word — which re-splits the whole transcript — redraws paragraph 4
        // into paragraph 3's view, carrying the selection highlight and any
        // open edit field to the wrong words.
        let words = [Self.word("a", 0.0, 0.2), Self.word("b", 1.0, 0.2), Self.word("c", 1.2, 0.2)]
        let paragraphs = TranscriptParagraphs.split(words)
        #expect(paragraphs.map(\.id) == [words[0].id, words[1].id])

        // Dropping the first line leaves the second line's id unchanged.
        let after = TranscriptParagraphs.split(Array(words.dropFirst()))
        #expect(after.map(\.id) == [words[1].id])
    }

    @Test("An empty transcript produces no paragraphs rather than one empty one")
    func emptyTranscript() {
        #expect(TranscriptParagraphs.split([]).isEmpty)
    }

    @Test("The shipped threshold sits between a clause pause and a thought pause")
    func thresholdIsInTheUsefulRange() {
        // The constant itself. Below ~0.35s it starts cutting inside
        // sentences; above ~1s it stops firing on the beats a narrator
        // actually leaves between actions.
        #expect(TranscriptParagraphs.breakSeconds >= 0.35)
        #expect(TranscriptParagraphs.breakSeconds <= 1.0)
    }
}
