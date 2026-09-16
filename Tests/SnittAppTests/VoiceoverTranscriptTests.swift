// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// Narration in the transcript: merged with recorded speech, told apart by
/// colour, and hidden when its track is muted.
@Suite(.serialized)
@MainActor
struct VoiceoverTranscriptTests {
    init() { _ = NSApplication.shared }

    private func word(_ text: String, at start: Double, track: String) -> TranscriptWord {
        TranscriptWord(text: text, start: start, duration: 0.3, confidence: 1, track: track)
    }

    // MARK: - Merging

    /// A take covering source 2-3.
    private func take(from start: Double = 2, to end: Double = 3) -> Overdub {
        Overdub(filename: "t.m4a", durationSeconds: end - start,
                segments: [OverdubSegment(takeStart: 0, sourceStart: start,
                                          durationSeconds: end - start)])
    }

    @Test("Both sources land in one transcript, in time order")
    func mergeInterleavesByTime() throws {
        // They INTERLEAVE rather than concatenate: a take is recorded over
        // footage that already has speech either side of it, so appending one
        // list to the other would put every re-recorded word after every
        // captured one however early it was said.
        let spoken = Transcript(words: [word("first", at: 1, track: "microphone"),
                                        word("third", at: 5, track: "microphone")],
                                locale: "en-US")
        let merged = try #require(Transcriber.merge(
            spoken, overdubs: [take()],
            takeWords: [word("second", at: 2.5, track: "microphone")]))
        #expect(merged.words.map(\.text) == ["first", "second", "third"])
    }

    @Test("Captured words UNDER a take are dropped, not kept beside it")
    func coveredWordsAreReplaced() throws {
        // THE D102 CHANGE. A take replaces the microphone for its span, so the
        // capture's own words there are not in the file anybody will watch.
        // Keeping them would put two different sentences on the same second
        // and invite editing against audio that no longer exists.
        let spoken = Transcript(words: [word("before", at: 1, track: "microphone"),
                                        word("replaced", at: 2.5, track: "microphone"),
                                        word("after", at: 5, track: "microphone")],
                                locale: "en-US")
        let merged = try #require(Transcriber.merge(
            spoken, overdubs: [take()],
            takeWords: [word("instead", at: 2.5, track: "microphone")]))
        #expect(merged.words.map(\.text) == ["before", "instead", "after"],
                "got \(merged.words.map(\.text))")
    }

    @Test("Words either side of a take survive exactly")
    func uncoveredWordsSurvive() throws {
        // The boundary, both ends. A take covering 2-3 must not take a word at
        // 3 with it: `covers` is half-open, so a word starting where a take
        // ends belongs to the capture again.
        let spoken = Transcript(words: [word("in", at: 2.0, track: "microphone"),
                                        word("out", at: 3.0, track: "microphone")],
                                locale: "en-US")
        let merged = try #require(Transcriber.merge(
            spoken, overdubs: [take()], takeWords: []))
        #expect(merged.words.map(\.text) == ["out"])
    }

    @Test("A recording with no microphone still gets a transcript from a take")
    func takeAloneProducesATranscript() throws {
        // A recording made with the mic off and spoken over afterwards. Gating
        // the take pass on the capture pass having found something would leave
        // exactly this case empty.
        let merged = try #require(Transcriber.merge(
            nil, overdubs: [take()],
            takeWords: [word("recorded later", at: 2.5, track: "microphone")]))
        #expect(merged.words.map(\.text) == ["recorded later"])
    }

    @Test("No takes leaves the transcript untouched")
    func noTakesIsIdentity() throws {
        let spoken = Transcript(words: [word("a", at: 1, track: "microphone")], locale: "en-US")
        let merged = try #require(Transcriber.merge(spoken, overdubs: [], takeWords: []))
        #expect(merged.words.count == 1)
        #expect(merged.locale == "en-US", "the merge invented a locale")
    }

    @Test("Neither source means no transcript, rather than an empty one")
    func nothingMeansNil() {
        // Nil and empty are different states for the pane: one says "nothing
        // was transcribed", the other draws a list with nothing in it under a
        // heading reading "0 words".
        #expect(Transcriber.merge(nil, overdubs: [], takeWords: []) == nil)
    }

    // MARK: - The wire

    @Test("A transcript written before narration existed still reads")
    func olderTranscriptsDecode() throws {
        // `track` is additive. The synthesised decoder would throw
        // `keyNotFound` on every transcript written before narration existed —
        // which is all of them — and D60's version gate would not catch it,
        // because the schema version did not move for an additive field.
        let json = """
        {"schemaVersion":1,"locale":"en-US","words":[
          {"id":"\(UUID().uuidString)","text":"hello","start":1,"duration":0.3,"confidence":1}
        ]}
        """
        let decoded = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        #expect(decoded.words.first?.track == "microphone")
    }

    @Test("A recording with no narration writes the same bytes it always did")
    func microphoneWordsWriteNoTrackKey() throws {
        let transcript = Transcript(words: [word("a", at: 1, track: "microphone")],
                                    locale: "en-US")
        let json = try #require(String(data: JSONEncoder().encode(transcript), encoding: .utf8))
        #expect(!json.contains("track"))
    }

    @Test("Narration DOES write its track, or it would read back as microphone")
    func voiceoverWordsWriteTheirTrack() throws {
        let transcript = Transcript(words: [word("a", at: 1, track: "voiceover")],
                                    locale: "en-US")
        let data = try JSONEncoder().encode(transcript)
        #expect(try JSONDecoder().decode(Transcript.self, from: data)
            .words.first?.track == "voiceover")
    }

    // MARK: - Muting

    @Test("Muting a track hides its words in BOTH surfaces")
    func mutingHidesFromPaneAndLane() async throws {
        // One derivation feeds the reading pane and the timeline lane, so they
        // cannot disagree about what is audible. Asserted through the state's
        // own `audibleWords`, which is what both read.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "votx-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 2.0, audioTrackCount: 2)
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)

        var edl = EditDecisionList()
        edl.trackStates = [TrackState(track: "microphone"), TrackState(track: "voiceover")]
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: edl, events: [])
        state.transcript = Transcript(words: [word("spoken", at: 0.5, track: "microphone"),
                                              word("narrated", at: 0.6, track: "voiceover")],
                                      locale: "en-US")

        #expect(state.audibleWords.count == 2)

        state.setMuted(track: "voiceover", muted: true)
        #expect(state.audibleWords.map(\.text) == ["spoken"])

        state.setMuted(track: "microphone", muted: true)
        #expect(state.audibleWords.isEmpty)

        state.setMuted(track: "voiceover", muted: false)
        #expect(state.audibleWords.map(\.text) == ["narrated"])
    }
}

/// Re-transcribing a take the moment it is recorded (D102).
///
/// Without it the transcript is a lie the instant a take lands: it still shows
/// what the CAPTURED microphone said over those seconds — audio the export has
/// replaced — and none of what was just said instead. Worse than stale, because
/// the words left on screen are specifically the ones the take exists to remove.
struct AutoTranscribeTakeTests {

    private func word(_ text: String, at start: Double,
                      track: String = "microphone") -> TranscriptWord {
        TranscriptWord(text: text, start: start, duration: 0.3, confidence: 1, track: track)
    }

    private func take(from start: Double, to end: Double) -> Overdub {
        Overdub(filename: "t.m4a", durationSeconds: end - start,
                segments: [OverdubSegment(takeStart: 0, sourceStart: start,
                                          durationSeconds: end - start)])
    }

    // MARK: - The consent gate

    @Test("A recording that has never been transcribed is left alone")
    func noTranscriptMeansNoAutoRun() {
        // Transcription is consent-gated (§4.10 asks at first USE), so a take
        // must not push a document through the Speech grant. Having a
        // transcript IS the opt-in.
        #expect(!Transcriber.shouldAutoTranscribeTake(hasTranscript: false,
                                                      availability: .available))
    }

    @Test("A recording that HAS one is kept up to date")
    func transcriptMeansAutoRun() {
        #expect(Transcriber.shouldAutoTranscribeTake(hasTranscript: true,
                                                     availability: .available))
    }

    @Test("An unavailable or refused recogniser is never invoked")
    func unavailableIsNeverRun() {
        // Both directions matter: `notYetRequested` would raise a dialog with
        // no visible cause, and `denied` would ask again after a no.
        #expect(!Transcriber.shouldAutoTranscribeTake(hasTranscript: true,
                                                      availability: .notYetRequested))
        #expect(!Transcriber.shouldAutoTranscribeTake(hasTranscript: true,
                                                      availability: .denied))
        #expect(!Transcriber.shouldAutoTranscribeTake(hasTranscript: true,
                                                      availability: .unsupported))
    }

    // MARK: - Merging just the new take

    @Test("The new take replaces the words under IT")
    func newTakeReplacesItsOwnSpan() throws {
        let before = Transcript(words: [word("keep", at: 1),
                                        word("replaced", at: 5.5),
                                        word("also keep", at: 9)],
                                locale: "en-US")
        let merged = try #require(Transcriber.merging(
            take(from: 5, to: 6), words: [word("said instead", at: 5.5)], into: before))
        #expect(merged.words.map(\.text) == ["keep", "said instead", "also keep"])
    }

    @Test("An EARLIER take's words survive a later take being transcribed")
    func earlierTakesAreNotRedropped() throws {
        // THE SUBTLETY. Take words are tagged `microphone` and are
        // indistinguishable from captured ones, so merging against EVERY take
        // would drop the words of takes that were transcribed earlier — they
        // sit under a take's span by construction. Passing only the NEW take
        // means the words dropped are exactly the ones it replaced.
        let afterFirstTake = Transcript(words: [word("from take one", at: 2.5),
                                                word("captured", at: 8)],
                                        locale: "en-US")
        let merged = try #require(Transcriber.merging(
            take(from: 7, to: 9), words: [word("from take two", at: 8)],
            into: afterFirstTake))
        #expect(merged.words.map(\.text) == ["from take one", "from take two"],
                "got \(merged.words.map(\.text))")
    }

    @Test("Surviving captured words keep their ORIGINAL times")
    func mergingShiftsNothing() throws {
        // Reported as "the original microphone transcription gets offset by
        // the length of the overdub". The composition is not where that comes
        // from — `OverdubTimingTests` pins the microphone to the picture's
        // length — it is that the words under a take were STALE until a take
        // re-transcribed. For the take's duration you read one thing and heard
        // another, which reads as an offset exactly that wide.
        //
        // This is the other half: merging must move nothing. A merge that
        // re-timed the survivors would introduce the very drift the staleness
        // only impersonated.
        let before = Transcript(words: [word("early", at: 1.0),
                                        word("under", at: 5.5),
                                        word("late", at: 12.25)],
                                locale: "en-US")
        let merged = try #require(Transcriber.merging(
            take(from: 5, to: 6), words: [word("new", at: 5.5)], into: before))
        let byText = Dictionary(uniqueKeysWithValues: merged.words.map { ($0.text, $0.start) })
        #expect(byText["early"] == 1.0)
        #expect(byText["late"] == 12.25, "a surviving word moved to \(byText["late"] ?? -1)")
    }

    @Test("A take the recogniser heard nothing in still clears what it replaced")
    func silentTakeStillClears() throws {
        // Recording silence over a sentence removes the sentence: the audio
        // that said it is not in the file any more, so neither should the
        // words be. Leaving them would caption speech nobody can hear.
        let before = Transcript(words: [word("gone", at: 5.5)], locale: "en-US")
        let merged = try #require(Transcriber.merging(
            take(from: 5, to: 6), words: [], into: before))
        #expect(merged.words.isEmpty, "got \(merged.words.map(\.text))")
    }
}
