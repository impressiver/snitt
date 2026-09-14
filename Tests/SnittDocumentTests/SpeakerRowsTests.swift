// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// One voice per line, in the reading pane and on the timeline's phrase lane.
///
/// Reported as "the transcription panel needs to split the two lanes into
/// separate rows". The recogniser emits a single stream ordered by time, so a
/// narrator talking over recorded speech produced lines that alternated
/// between them word by word — "so and here that we fails" — and the pane
/// coloured each word to say which was which. That is a legend for a sentence
/// nobody can read, not a fix.
struct SpeakerRowsTests {

    private func recorded(_ items: [(String, Double, Double)]) -> [TranscriptWord] {
        items.map { TranscriptWord(text: $0.0, start: $0.1, duration: $0.2, confidence: 1) }
    }

    private func narrated(_ items: [(String, Double, Double)]) -> [TranscriptWord] {
        items.map { TranscriptWord(text: $0.0, start: $0.1, duration: $0.2,
                                   confidence: 1, track: "voiceover") }
    }

    /// Two voices whose words alternate: the case the old split produced one
    /// unreadable line for.
    private var interleaved: [TranscriptWord] {
        (recorded([("so", 1.0, 0.2), ("here", 1.4, 0.2), ("we", 1.8, 0.2)])
            + narrated([("and", 1.2, 0.2), ("that", 1.6, 0.2), ("fails", 2.0, 0.2)]))
            .sorted { $0.start < $1.start }
    }

    private func text(_ paragraph: TranscriptParagraph) -> String {
        paragraph.words.map(\.text).joined(separator: " ")
    }

    @Test("A line never mixes two voices")
    func linesAreSingleVoiced() {
        // THE BUG. Sorted into one stream and split on pauses alone, these six
        // words are a single line reading "so and here that we fails".
        let lines = TranscriptParagraphs.split(interleaved)
        #expect(lines.count == 2, "got \(lines.map(text))")
        #expect(Set(lines.map(text)) == ["so here we", "and that fails"])
        #expect(lines.allSatisfy { line in
            Set(line.words.map(\.track)).count == 1
        }, "a line contains words from more than one track")
    }

    @Test("Each line says which voice it is")
    func linesCarryTheirTrack() throws {
        // Without this the pane has to look inside a line to colour it, which
        // is what it used to do — per word, because per word was the only
        // level at which the answer was ever the same for the whole thing.
        let lines = TranscriptParagraphs.split(interleaved)
        let mic = try #require(lines.first { $0.track == "microphone" })
        let voice = try #require(lines.first { $0.track == "voiceover" })
        #expect(text(mic) == "so here we")
        #expect(text(voice) == "and that fails")
    }

    @Test("A voice is paragraphed on its OWN pauses, not on the other's words")
    func pausesAreMeasuredWithinAVoice() {
        // The distinguishing case, and the reason this is not just "split on a
        // track change". These three words are one continuous phrase with
        // narration falling in the gaps BETWEEN them. Splitting whenever the
        // track changes would give three one-word lines — worse than the wall
        // of words it replaced, and exactly when the two voices overlap most.
        let lines = TranscriptParagraphs.split(interleaved)
        let mic = lines.filter { $0.track == "microphone" }
        #expect(mic.count == 1, "the recorded phrase was shredded into \(mic.count) lines")
    }

    @Test("Lines still read down the recording in the order things were said")
    func linesAreInTimeOrder() {
        // Merging two streams must not put all of one voice above all of the
        // other — the pane is read top to bottom against a playhead.
        let words = recorded([("first", 0.0, 0.3)])
            + narrated([("second", 5.0, 0.3)])
            + recorded([("third", 10.0, 0.3)])
        let lines = TranscriptParagraphs.split(words)
        #expect(lines.map(text) == ["first", "second", "third"])
    }

    @Test("A recording with one voice is completely unchanged")
    func oneVoiceIsUntouched() {
        // The overwhelmingly common case. The split must not re-sort, re-group
        // or otherwise disturb a transcript that never had narration in it.
        let words = recorded([("one", 0.0, 0.3), ("two", 0.4, 0.3),
                              ("three", 3.0, 0.3)])
        let lines = TranscriptParagraphs.split(words)
        #expect(lines.map(text) == ["one two", "three"])
        #expect(lines.allSatisfy { $0.track == "microphone" })
    }

    @Test("Narration alone gets its own lines, not the microphone's label")
    func narrationAloneIsStillNarration() {
        // A recording narrated after the fact with the mic off. The track must
        // come from the words rather than from a default.
        let lines = TranscriptParagraphs.split(narrated([("only", 1.0, 0.3)]))
        #expect(lines.map(\.track) == ["voiceover"])
    }

    @Test("The phrase chips on the timeline are split the same way")
    func timelinePhrasesAgree() {
        // `TranscriptPhrases` builds on `split` precisely so the lane and the
        // prose cannot disagree about where a phrase ends. That has to survive
        // the voice split, or a chip spans two speakers while the line under
        // it does not.
        let phrases = TranscriptPhrases.phrases(from: interleaved)
        #expect(phrases.allSatisfy { phrase in
            Set(phrase.words.map(\.track)).count == 1
        }, "a timeline chip spans two voices: \(phrases.map(\.text))")
        #expect(Set(phrases.map(\.text)) == ["so here we", "and that fails"])
    }

    @Test("Empty input is still empty")
    func emptyIsEmpty() {
        #expect(TranscriptParagraphs.split([]).isEmpty)
    }
}

/// What counts as a separate voice, written once.
struct VoiceStreamTests {

    @Test("Narration is one voice and everything the recording captured is the other")
    func twoStreams() throws {
        // Narration-versus-everything-else rather than one stream per track
        // name. A voice is a person talking; if system audio is ever
        // transcribed it is a sound the recording captured, and a third column
        // is a design nobody has asked for.
        let words = [
            TranscriptWord(text: "mic", start: 0, duration: 0.2, confidence: 1),
            TranscriptWord(text: "sys", start: 0.3, duration: 0.2,
                           confidence: 1, track: "systemAudio"),
            TranscriptWord(text: "over", start: 0.6, duration: 0.2,
                           confidence: 1, track: "voiceover"),
        ]
        let voices = AudibleTranscript.voices(words)
        #expect(voices.count == 2, "system audio was given a stream of its own")
        #expect(voices[0].words.map(\.text) == ["mic", "sys"])
        #expect(voices[1].words.map(\.text) == ["over"])
    }

    @Test("The recorded voice comes first")
    func recordedLeads() {
        // Order is load-bearing: the caption merge reads stream 0 as the
        // recorded one and stream 1 as the narration, and places them on the
        // lower and upper lines accordingly.
        let words = [
            TranscriptWord(text: "over", start: 0, duration: 0.2,
                           confidence: 1, track: "voiceover"),
            TranscriptWord(text: "mic", start: 1, duration: 0.2, confidence: 1),
        ]
        #expect(AudibleTranscript.voices(words).map(\.track) == ["microphone", "voiceover"])
    }

    @Test("A voice with nothing to say gets no stream at all")
    func emptyVoicesAreOmitted() {
        // What keeps every caller's merge step a no-op for the recordings that
        // have one voice.
        let onlyMic = [TranscriptWord(text: "mic", start: 0, duration: 0.2, confidence: 1)]
        #expect(AudibleTranscript.voices(onlyMic).map(\.track) == ["microphone"])

        let onlyNarration = [TranscriptWord(text: "over", start: 0, duration: 0.2,
                                            confidence: 1, track: "voiceover")]
        #expect(AudibleTranscript.voices(onlyNarration).map(\.track) == ["voiceover"])
        #expect(AudibleTranscript.voices([]).isEmpty)
    }

    @Test("Every word survives the split")
    func nothingIsLost() {
        // A filter pair that disagreed about its predicate would drop words
        // silently, and a transcript missing a word reads as a recognition
        // failure rather than as a bug here.
        let words = (0..<10).map { index in
            TranscriptWord(text: "w\(index)", start: Double(index), duration: 0.2,
                           confidence: 1,
                           track: index.isMultiple(of: 3) ? "voiceover" : "microphone")
        }
        let rejoined = AudibleTranscript.voices(words).flatMap(\.words)
        #expect(Set(rejoined.map(\.text)) == Set(words.map(\.text)))
        #expect(rejoined.count == words.count)
    }
}
