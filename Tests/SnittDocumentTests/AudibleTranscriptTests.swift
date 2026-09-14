// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// Hiding the transcript for a track that is not in the output.
///
/// A muted track contributes nothing to the exported file, so its speech is
/// not in the recording anyone will watch. Leaving it visible invites editing
/// against something that is not there.
struct AudibleTranscriptTests {

    private func word(_ text: String, at start: Double, track: String) -> TranscriptWord {
        TranscriptWord(text: text, start: start, duration: 0.3, confidence: 1, track: track)
    }

    private let words = [
        TranscriptWord(text: "spoken", start: 1, duration: 0.3, confidence: 1,
                       track: "microphone"),
        TranscriptWord(text: "narrated", start: 1.1, duration: 0.3, confidence: 1,
                       track: "voiceover"),
    ]

    @Test("Nothing muted, nothing hidden")
    func unmutedKeepsEverything() {
        let states = [TrackState(track: "microphone"), TrackState(track: "voiceover")]
        #expect(AudibleTranscript.audible(words, trackStates: states).count == 2)
    }

    @Test("Muting the microphone hides its words and keeps the narration")
    func mutingOneTrackHidesOnlyThatTrack() {
        // The two overlap in time — narration is spoken OVER footage that
        // already has speech — so this cannot be done by time range. Only the
        // word's own track can answer it.
        let states = [TrackState(track: "microphone", muted: true),
                      TrackState(track: "voiceover")]
        let audible = AudibleTranscript.audible(words, trackStates: states)
        #expect(audible.map(\.text) == ["narrated"])
    }

    @Test("Muting the voiceover hides the narration and keeps the microphone")
    func mutingTheVoiceoverHidesNarration() {
        let states = [TrackState(track: "microphone"),
                      TrackState(track: "voiceover", muted: true)]
        #expect(AudibleTranscript.audible(words, trackStates: states).map(\.text) == ["spoken"])
    }

    @Test("Muting both leaves nothing")
    func mutingBothEmptiesTheTranscript() {
        let states = [TrackState(track: "microphone", muted: true),
                      TrackState(track: "voiceover", muted: true)]
        #expect(AudibleTranscript.audible(words, trackStates: states).isEmpty)
    }

    @Test("A word whose track has no state is KEPT")
    func unknownTrackSurvives() {
        // The older document, and the one that matters most: transcripts
        // written before narration existed carry no track at all and decode as
        // "microphone". Treating an absent state as muted would empty the
        // transcript of exactly the recordings that have the most of it.
        let audible = AudibleTranscript.audible(words, trackStates: [])
        #expect(audible.count == 2)

        // And with a state for only one of the two, the other still shows.
        let partial = AudibleTranscript.audible(
            words, trackStates: [TrackState(track: "voiceover", muted: true)])
        #expect(partial.map(\.text) == ["spoken"])
    }

    @Test("Gain does not hide anything, however low")
    func gainIsNotMuting() {
        // A quiet track is still in the output. Hiding its words would make the
        // transcript disagree with the file for every recording where somebody
        // pulled a level down rather than off — and the fader reaching zero is
        // a separate thing from the mute button, which is what this asks about.
        let states = [TrackState(track: "microphone", muted: false, gain: 0.0)]
        #expect(AudibleTranscript.audible(words, trackStates: states).count == 2)
    }

    @Test("Narration is distinguishable from recorded speech")
    func voiceoverIsIdentifiable() {
        // What the colour is drawn from. Named rather than compared inline,
        // because several surfaces need it and a repeated string literal is
        // several places to mistype.
        #expect(AudibleTranscript.isVoiceover(word("a", at: 0, track: "voiceover")))
        #expect(!AudibleTranscript.isVoiceover(word("a", at: 0, track: "microphone")))
    }
}
