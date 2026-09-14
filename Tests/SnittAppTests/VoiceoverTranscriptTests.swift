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

    @Test("Both sources land in one transcript, in time order")
    func mergeInterleavesByTime() throws {
        // They INTERLEAVE rather than concatenate: narration is spoken over
        // footage that already has speech in it, so appending one list to the
        // other would put every narrated word after every recorded one however
        // early it was said.
        let spoken = Transcript(words: [word("first", at: 1, track: "microphone"),
                                        word("third", at: 3, track: "microphone")],
                                locale: "en-US")
        let merged = try #require(Transcriber.merge(
            spoken, voiceover: [word("second", at: 2, track: "voiceover")]))
        #expect(merged.words.map(\.text) == ["first", "second", "third"])
    }

    @Test("A recording with no microphone still gets a transcript from narration")
    func narrationAloneProducesATranscript() throws {
        // A recording made with the mic off and narrated afterwards. Gating the
        // voiceover pass on the microphone pass having found something would
        // leave exactly this case empty.
        let merged = try #require(Transcriber.merge(
            nil, voiceover: [word("narrated", at: 1, track: "voiceover")]))
        #expect(merged.words.map(\.text) == ["narrated"])
    }

    @Test("No narration leaves the transcript untouched")
    func noVoiceoverIsIdentity() throws {
        let spoken = Transcript(words: [word("a", at: 1, track: "microphone")], locale: "en-US")
        let merged = try #require(Transcriber.merge(spoken, voiceover: []))
        #expect(merged.words.count == 1)
        #expect(merged.locale == "en-US", "the merge invented a locale")
    }

    @Test("Neither source means no transcript, rather than an empty one")
    func nothingMeansNil() {
        // Nil and empty are different states for the pane: one says "nothing
        // was transcribed", the other draws a list with nothing in it under a
        // heading reading "0 words".
        #expect(Transcriber.merge(nil, voiceover: []) == nil)
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
