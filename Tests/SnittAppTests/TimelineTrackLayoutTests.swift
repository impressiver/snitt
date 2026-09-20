// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import CoreGraphics
@testable import SnittApp
@testable import SnittDocument

// One timeline band per audio source (D56 Tier 1).
//
// Task 6 delivered three bands — markers, video, audio — and drew BOTH audio
// sources into the single audio band. Two consequences: a recording with the
// microphone on looked identical to one without, and TrackState.muted, carried
// in the model since M3, had no representation at all — muting changed the
// export and nothing on screen.
@Suite
struct TimelineTrackLayoutTests {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 56)
    private let markerHeight = 14.0

    // WHICH sources get a lane is asserted in `AudioTrackVisibilityTests`
    // now (D110), in `SnittDocumentTests`, which CI can actually run.
    //
    // The test that stood here is worth remembering rather than just
    // deleting. It said "a recording made with the microphone off must not get
    // an empty mic lane", and it passed for years while exactly that happened
    // on every such recording — because what it actually checked was that the
    // filter removes a microphone from a list that has no microphone in it.
    // No mic-off recording ever produced that list: `fullRange()` writes both
    // audio states at `start()`. A proxy stood in for the property, the proxy
    // held, and the property never did.

    @Test("Two audio sources get two bands, and they do not overlap")
    func twoSourcesGetTwoBands() {
        let bands = TimelineTrackLayout.bands(in: bounds, markerHeight: markerHeight,
                                              audioTracks: ["microphone", "systemAudio"])
        #expect(bands.audio.count == 2)
        let mic = bands.audio[0].rect, system = bands.audio[1].rect
        // The defect this replaces drew ONE rect. A version that returned two
        // identical rects would also "have two bands" — the overlap assertion
        // is what distinguishes stacked from superimposed.
        #expect(mic.maxY <= system.minY + 0.001, "audio bands overlap")
        #expect(abs(mic.height - system.height) < 0.001)
        #expect(mic.minY >= bands.video.maxY - 0.001, "audio drawn over video")
    }

    @Test("A single source takes the whole audio allowance")
    func oneSourceFillsTheAudioBand() {
        // Not half of it with a dead strip below — that would read as a second,
        // silent source.
        let two = TimelineTrackLayout.bands(in: bounds, markerHeight: markerHeight,
                                            audioTracks: ["microphone", "systemAudio"])
        let one = TimelineTrackLayout.bands(in: bounds, markerHeight: markerHeight,
                                            audioTracks: ["systemAudio"])
        #expect(one.audio.count == 1)
        #expect(abs(one.audio[0].rect.height - (two.audio[0].rect.height * 2)) < 0.001)
        #expect(abs(one.audio[0].rect.maxY - bounds.maxY) < 0.001)
    }

    @Test("What is DRAWN matches what is PLANNED")
    func bandsMatchThePlan() {
        // The bug this exists to prevent, and it shipped: `bands` — the code
        // that draws — carried its own `remaining * 0.6` while
        // `TimelineLaneBudget.videoShareOfSurplus` was tuned 0.6 -> 0.3 ->
        // 0.15 across three commits. The type that was tested was not the type
        // that rendered, so two rounds of "halve the filmstrip" changed
        // nothing on screen and every test still passed.
        //
        // Asserted as agreement between the two rather than against a number,
        // because a number here would have to be edited in step with the
        // constant and would therefore never catch this.
        let height: Double = 300
        let tracks = ["microphone", "systemAudio"]
        let drawn = TimelineTrackLayout.bands(
            in: CGRect(x: 0, y: 0, width: 800, height: height),
            markerHeight: TimelineLaneBudget.minimumTargetHeight,
            audioTracks: tracks, hasTranscript: false)
        let planned = TimelineLaneBudget.plan(
            availableHeight: height, audioTracks: tracks, hasTranscript: false)

        #expect(abs(drawn.video.height - (planned.height(of: .video) ?? 0)) < 0.001,
                "the drawn filmstrip does not match the planned one")
        for track in tracks {
            let drawnHeight = drawn.audio.first { $0.track == track }?.rect.height ?? 0
            #expect(abs(drawnHeight - (planned.height(of: .audio(track)) ?? 0)) < 0.001,
                    "a drawn audio band does not match the planned one")
        }
    }

    @Test("The marker lane meets the filmstrip directly — cuts take no band")
    func noBandBetweenMarksAndVideo() {
        // Cuts used to hold a 24pt lane here, and rev 5 (W11) gives it back:
        // a cut collapses the whole stack, so it draws as a full-height seam
        // across every lane rather than as a strip of its own. What this
        // asserts is the consequence a reader can see — nothing sits between
        // the marks and the picture, whether or not the recording has cuts.
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 300)
        let bands = TimelineTrackLayout.bands(in: bounds, markerHeight: 24,
                                              audioTracks: ["microphone"])
        #expect(abs(bands.marker.maxY - bands.video.minY) < 0.001,
                "a gap survived between the marker lane and the filmstrip")
    }

    @Test("Bands tile the view with no gap and no overflow")
    func bandsTileTheView() {
        let bands = TimelineTrackLayout.bands(in: bounds, markerHeight: markerHeight,
                                              audioTracks: ["microphone", "systemAudio"])
        #expect(bands.marker.minY == 0)
        #expect(abs(bands.marker.maxY - bands.video.minY) < 0.001)
        let total = bands.marker.height + bands.video.height
                  + bands.audio.reduce(0) { $0 + $1.rect.height }
                  + bands.transcript.height
        #expect(abs(total - bounds.height) < 0.001, "bands do not fill the view")
    }

    @Test("No audio sources leaves video and markers intact")
    func noAudioIsNotACrash() {
        let bands = TimelineTrackLayout.bands(in: bounds, markerHeight: markerHeight, audioTracks: [])
        #expect(bands.audio.isEmpty)
        #expect(bands.video.height > 0)
    }
}
