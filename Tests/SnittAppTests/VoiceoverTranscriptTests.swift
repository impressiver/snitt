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
