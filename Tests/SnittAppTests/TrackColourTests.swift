// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import SwiftUI
@testable import SnittApp
@testable import SnittBrand
@testable import SnittDocument

/// One colour per track, everywhere that track is drawn.
///
/// Reported as "make the vu meter orange match the lane blue": the voiceover
/// lane and its transcript words were both teal, and the VU ladder standing
/// against that lane, measuring that audio, was still amber. Three renderers
/// each picked a colour for themselves and two of them agreed.
///
/// These assert IDENTITY against the lane rather than "the voiceover meter is
/// teal". A literal would keep passing after somebody re-tuned the lane and
/// left the ladder behind — which is exactly the defect being fixed, so a test
/// that cannot see it happen again is not worth writing.
@Suite
@MainActor
struct TrackColourTests {

    private func srgb(_ color: Color) -> NSColor { NSColor(color).usingColorSpace(.sRGB)! }
    private func srgb(_ color: NSColor) -> NSColor { color.usingColorSpace(.sRGB)! }

    /// A lit segment below unity, where the track's own colour is used.
    private func litColour(_ track: String) -> NSColor {
        let view = GainMeterView(title: "x", track: track, gain: 0.7, muted: false,
                                 onGain: { _ in }, onToggleMute: {})
        // Gain 0.7 is about -3 dB, so segment 0 is lit and well below unity.
        #expect(GainMeter.litSegments(forGain: 0.7) > 0, "the fixture lit no segments")
        #expect(!GainMeter.isHot(segment: 0), "segment 0 is hot — this fixture tests the wrong branch")
        return srgb(view.colourForTesting(0))
    }

    @Test("Every track's ladder is the same colour as its own waveform")
    func ladderMatchesItsLane() {
        // All three, not just the voiceover: a special case for narration
        // would leave the rule ("a ladder is the colour of the lane it
        // measures") untested for the tracks that already agreed by accident.
        for track in AudioTrackOrder.canonical {
            #expect(litColour(track)
                    == srgb(TimelineView.Palette.waveform(for: track, muted: false)),
                    "the \(track) ladder does not match the \(track) lane")
        }
    }

    @Test("The voiceover ladder is a DIFFERENT colour from the recorded ones")
    func narrationLadderStandsApart() {
        // The assertion above is satisfied by a palette that returns one
        // colour for everything. This is what makes it say something.
        #expect(litColour("voiceover") != litColour("microphone"))
        #expect(litColour("microphone") == litColour("systemAudio"),
                "the two recorded sources should not have been given separate colours")
    }

    @Test("A ladder and its transcript words agree too")
    func ladderMatchesTheTranscript() {
        // The third renderer. `TranscriptPane` draws voiceover words in
        // `SnittPalette.voiceover`; a meter that matched the lane but not the
        // words would just move the disagreement.
        #expect(litColour("voiceover") == srgb(SnittPalette.voiceover))
    }

    @Test("Clipping is red on every track, including narration")
    func hotIsRedRegardless() {
        // A teal "hot" would be a warning only some tracks get to give. The
        // track colour says WHOSE audio this is; red says something is wrong
        // with it, and those are different questions.
        for track in AudioTrackOrder.canonical {
            let view = GainMeterView(title: "x", track: track, gain: 3.0, muted: false,
                                     onGain: { _ in }, onToggleMute: {})
            #expect(srgb(view.colourForTesting(GainMeter.unitySegment))
                    == srgb(SnittPalette.Swatch.recordRed),
                    "\(track) does not warn about clipping in red")
        }
    }

    @Test("An unknown track falls back to the recorded colour rather than to nothing")
    func unknownTrackIsAmber() {
        // A `switch` with no default, or a dictionary lookup returning nil
        // through `??  .clear`, would make a future track invisible. Amber is
        // the assumption worth making: an unrecognised track is a recorded
        // source until somebody says otherwise.
        #expect(SnittPalette.track("somethingNew") == SnittPalette.signal)
    }

    @Test("The palette answers by track name, not by lane position")
    func colourIsNotPositional() {
        // The lane order changed in this same commit. A colour picked by index
        // would have silently followed it — and that defect has shipped here
        // before, when system audio was given the state named "video".
        let byName = AudioTrackOrder.canonical.map(SnittPalette.track)
        let reversed = AudioTrackOrder.canonical.reversed().map(SnittPalette.track)
        #expect(byName == Array(reversed.reversed()))
        #expect(SnittPalette.track("voiceover") != SnittPalette.track("systemAudio"))
    }
}

/// Which lane sits above which, and why that is not a matter of taste.
@Suite
struct AudioLaneOrderTests {

    @Test("Lanes read in the order the tracks exist in the file")
    func laneOrderMatchesTheComposition() {
        // System audio is track 0, the microphone is track 1, the voiceover is
        // track 2 — that is what `AssetWriterSink` writes and what an audio
        // mix addresses. The lanes used to run microphone-first, so the one
        // place a human reads the track order disagreed with the only place it
        // is load-bearing.
        let states = AudioTrackOrder.canonical.map { TrackState(track: $0) }
        let lanes = AudioTrackOrder.recorded(in: states, health: nil, overdubbed: false)
        let indices = lanes.map { AudioTrackOrder.canonical.firstIndex(of: $0)! }
        #expect(indices == indices.sorted(), "lanes are not in composition order: \(lanes)")
        #expect(lanes == ["systemAudio", "microphone", "voiceover"])
    }

    @Test("The order is derived, not a second list that happens to agree")
    func orderIsNotACopy() {
        // Two lists drift the moment either is touched, and this one already
        // had: `canonical` was corrected to put system audio first and the
        // lane list was not. Shuffling the input proves the answer comes from
        // `canonical` rather than from the caller.
        let shuffled = [TrackState(track: "voiceover"), TrackState(track: "microphone"),
                        TrackState(track: "systemAudio")]
        #expect(AudioTrackOrder.recorded(in: shuffled, health: nil, overdubbed: false) == AudioTrackOrder.canonical)
    }

    @Test("A recording without a microphone still orders what it has")
    func missingSourcesDoNotReorder() {
        // Dropping a track must close the gap, not leave a hole or reshuffle
        // the survivors.
        let states = [TrackState(track: "voiceover"), TrackState(track: "systemAudio")]
        #expect(AudioTrackOrder.recorded(in: states, health: nil, overdubbed: false) == ["systemAudio", "voiceover"])
        #expect(AudioTrackOrder.recorded(in: [TrackState(track: "video")],
                                         health: nil, overdubbed: false).isEmpty,
                "video is not an audio lane")
    }

    @Test("The gutter's meters line up with the bands they control")
    func gutterAgreesWithTheBands() {
        // The ladder is a separate view from the waveform, laid out from the
        // same plan. If the two ever derived their order independently, every
        // meter would control the lane next to it — a bug that looks like
        // nothing at all until you drag one.
        let states = AudioTrackOrder.canonical.map { TrackState(track: $0) }
        let tracks = AudioTrackOrder.recorded(in: states, health: nil, overdubbed: false)
        let plan = TimelineLaneBudget.plan(availableHeight: 240, audioTracks: tracks,
                                           hasTranscript: false)
        let planned = plan.lanes.compactMap { lane -> String? in
            if case .audio(let track) = lane.lane { return track }
            return nil
        }
        #expect(planned == tracks, "the gutter's lanes are not the timeline's bands")
    }
}
