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

    @Test("Audio sources come from the recording, not from a fixed list")
    func audioTracksAreDerived() {
        // A recording made with the microphone off must not get an empty mic
        // lane implying a source that was never captured.
        let withMic = [TrackState(track: "video"), TrackState(track: "microphone"),
                       TrackState(track: "systemAudio")]
        #expect(TimelineTrackLayout.audioTracks(in: withMic) == ["microphone", "systemAudio"])

        let withoutMic = [TrackState(track: "video"), TrackState(track: "systemAudio")]
        #expect(TimelineTrackLayout.audioTracks(in: withoutMic) == ["systemAudio"])
    }

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

    @Test("Bands tile the view with no gap and no overflow")
    func bandsTileTheView() {
        let bands = TimelineTrackLayout.bands(in: bounds, markerHeight: markerHeight,
                                              audioTracks: ["microphone", "systemAudio"])
        // The fold lane now sits between marks and video, and it appears in
        // views this test's height did not previously reach — lowering the
        // video floor to 18 made room for it. Counted rather than skipped: a
        // tiling test that ignored a real band would stop being a tiling test.
        #expect(bands.marker.minY == 0)
        #expect(abs(bands.marker.maxY - bands.fold.minY) < 0.001)
        #expect(abs(bands.fold.maxY - bands.video.minY) < 0.001)
        let total = bands.marker.height + bands.fold.height + bands.video.height
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
