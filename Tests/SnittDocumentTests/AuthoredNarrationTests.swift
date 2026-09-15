// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// Narration somebody writes rather than narration the recogniser hears (D100).
///
/// The input half of speech synthesis: stand at a moment, type what should be
/// said there, and it becomes a phrase on the voiceover track.
struct AuthoredNarrationTests {

    @Test("A written line becomes one word per word")
    func textBecomesWords() {
        // Per word, not one long word: every surface downstream is built on
        // words — the caption grouper, the phrase chips, the current-word
        // highlight — and a phrase pretending to be one would highlight all at
        // once and could never be split by a cut.
        let words = AuthoredNarration.words("and here it fails", sourceStart: 10)
        #expect(words.map(\.text) == ["and", "here", "it", "fails"])
    }

    @Test("It lands on the voiceover track, marked as written")
    func wordsAreNarrationAndAuthored() {
        // Voiceover because it is narration, and authored because the
        // difference decides what deleting it means.
        let words = AuthoredNarration.words("hello there", sourceStart: 0)
        #expect(words.allSatisfy { $0.track == "voiceover" })
        #expect(words.allSatisfy { $0.isAuthored })
        // Full confidence: a human typed it, so the recogniser's doubt-dimming
        // does not apply.
        #expect(words.allSatisfy { $0.confidence == 1.0 })
    }

    @Test("It starts where it was placed and runs forward from there")
    func timingsStartAtTheAnchor() throws {
        let words = AuthoredNarration.words("one two three", sourceStart: 12.5)
        let first = try #require(words.first)
        #expect(abs(first.start - 12.5) < 1e-9)
        // Ascending and contiguous — a line whose words overlap or run
        // backwards breaks the paragraph splitter and the caption grouper
        // alike.
        for (a, b) in zip(words, words.dropFirst()) {
            #expect(b.start >= a.end - 1e-9, "'\(a.text)' overruns '\(b.text)'")
        }
    }

    @Test("A line is timed at the same reading speed the captions use")
    func timingMatchesTheReadingSpeed() throws {
        // Two constants for "how long does this text take" would let an
        // authored line be captioned for a length its own text was never
        // measured against.
        #expect(AuthoredNarration.wordsPerSecond == SpeechRate.wordsPerSecond)
        let words = AuthoredNarration.words("a b c d e f", sourceStart: 0)
        let last = try #require(words.last)
        #expect(abs(last.end - 6 / SpeechRate.wordsPerSecond) < 1e-9,
                "six words took \(last.end)s")
    }

    @Test("Whitespace is not a line")
    func blankTextYieldsNothing() {
        // Refused here so no caller has to decide what an empty phrase on the
        // timeline means.
        #expect(AuthoredNarration.words("", sourceStart: 0).isEmpty)
        #expect(AuthoredNarration.words("   \n\t ", sourceStart: 0).isEmpty)
    }

    @Test("Runs of whitespace collapse rather than producing empty words")
    func whitespaceIsCollapsed() {
        // A double space between sentences is ordinary typing, and an empty
        // word would draw as a gap that can be selected and deleted.
        let words = AuthoredNarration.words("one   two\n\nthree", sourceStart: 0)
        #expect(words.map(\.text) == ["one", "two", "three"])
    }

    @Test("A new line is merged into the transcript in time order")
    func insertionKeepsTimeOrder() {
        // Every consumer assumes it: `TranscriptParagraphs` walks the list
        // looking for pauses, so a phrase appended at the end but anchored at
        // the beginning reads as one enormous gap and a line out of sequence.
        let existing = [
            TranscriptWord(text: "first", start: 0, duration: 0.3, confidence: 1),
            TranscriptWord(text: "last", start: 20, duration: 0.3, confidence: 1),
        ]
        let written = AuthoredNarration.words("middle", sourceStart: 10)
        let merged = AuthoredNarration.inserting(written, into: existing)
        #expect(merged.map(\.text) == ["first", "middle", "last"])
    }

    @Test("A line placed at the same instant as speech does not reorder it")
    func insertionIsStable() {
        // A written line anchored exactly where somebody was talking. Sorting
        // that is not stable would shuffle the speech around it, which looks
        // like the transcript rewriting itself.
        let existing = [
            TranscriptWord(text: "spoken", start: 5, duration: 0.3, confidence: 1),
            TranscriptWord(text: "also", start: 5, duration: 0.3, confidence: 1),
        ]
        let merged = AuthoredNarration.inserting(
            AuthoredNarration.words("written", sourceStart: 5), into: existing)
        #expect(merged.map(\.text) == ["spoken", "also", "written"])
    }

    @Test("Inserting nothing changes nothing")
    func insertingNothingIsANoOp() {
        let existing = [TranscriptWord(text: "a", start: 1, duration: 0.3, confidence: 1)]
        #expect(AuthoredNarration.inserting([], into: existing).map(\.text) == ["a"])
    }
}

/// `isAuthored` on the wire.
struct AuthoredWordCodingTests {

    @Test("An older transcript still decodes, as not-authored")
    func absentKeyDecodesToFalse() throws {
        // Every word written before this existed has no such key, and a
        // synthesised decoder would throw `keyNotFound` on all of them —
        // the same trap `track` documented, and one D60's version gate would
        // not catch, because the schema version does not move for an additive
        // field.
        let json = Data("""
        {"id":"\(UUID().uuidString)","text":"old","start":1,"duration":0.3,"confidence":0.9}
        """.utf8)
        let word = try JSONDecoder().decode(TranscriptWord.self, from: json)
        #expect(!word.isAuthored)
        #expect(word.track == "microphone")
    }

    @Test("A recording with no written narration produces the bytes it always did")
    func falseIsNotWritten() throws {
        let word = TranscriptWord(text: "heard", start: 1, duration: 0.3, confidence: 0.9)
        let encoded = try JSONEncoder().encode(word)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("isAuthored"),
                "a key was added to every word of every existing transcript")
    }

    @Test("A written line survives a round trip")
    func authoredRoundTrips() throws {
        let word = try #require(AuthoredNarration.words("written", sourceStart: 3).first)
        let data = try JSONEncoder().encode(word)
        #expect(String(decoding: data, as: UTF8.self).contains("isAuthored"))
        let back = try JSONDecoder().decode(TranscriptWord.self, from: data)
        #expect(back.isAuthored)
        #expect(back.track == "voiceover")
        #expect(back == word)
    }
}
