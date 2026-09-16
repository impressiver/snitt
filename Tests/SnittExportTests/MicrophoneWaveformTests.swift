// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittExport
@testable import SnittDocument

/// The microphone lane, once takes have been recorded over it (D102).
///
/// A take's file is indexed by its own clock — audio recorded over source
/// 30-36 starts at second 0 of that file — while `TimelineView` draws every
/// lane by mapping pixel columns into SOURCE seconds. Re-indexing here is what
/// lets the timeline draw this with the code it already has.
struct MicrophoneWaveformTests {

    private let rate: Double = 10

    private func capture(_ peaks: [Float]) -> WaveformSamples {
        WaveformSamples(track: "microphone", samplesPerSecond: rate, peaks: peaks)
    }

    private func take(_ peaks: [Float], segments: [OverdubSegment]) -> MicrophoneWaveform.Take {
        MicrophoneWaveform.Take(
            overdub: Overdub(filename: "t.m4a",
                             durationSeconds: Double(peaks.count) / rate,
                             segments: segments),
            samples: WaveformSamples(track: "microphone", samplesPerSecond: rate, peaks: peaks))
    }

    @Test("A take lands at the SOURCE time it was spoken over, not at zero")
    func takeIsSourceAligned() {
        // Left unmapped, a take would draw at the beginning of the recording
        // and drift further from the picture the later it was spoken.
        let result = MicrophoneWaveform.overdubbed(
            capture([Float](repeating: 0.1, count: 50)),
            takes: [take([0.9, 0.9, 0.9],
                         segments: [OverdubSegment(takeStart: 0, sourceStart: 2.0,
                                                   durationSeconds: 0.3)])],
            sourceDuration: 5.0)
        // 2.0s at 10 samples/s is index 20.
        #expect(result.peaks[20] == 0.9)
        #expect(result.peaks[21] == 0.9)
        #expect(result.peaks[19] == 0.1, "the take bled backwards into the capture")
        #expect(result.peaks[23] == 0.1, "the take bled forwards into the capture")
    }

    @Test("The take REPLACES the capture rather than being mixed with it")
    func takeReplacesTheCapture() {
        // THE D102 CHANGE. Under a third track both were audible and the lane
        // took the louder of the two; a take is heard INSTEAD of what was
        // captured, so a lane showing the louder would draw audio the export
        // has thrown away. Deliberately QUIETER than the capture, which is the
        // only fixture that can tell `max` from assignment.
        let result = MicrophoneWaveform.overdubbed(
            capture([Float](repeating: 0.9, count: 50)),
            takes: [take([0.2, 0.2],
                         segments: [OverdubSegment(takeStart: 0, sourceStart: 1.0,
                                                   durationSeconds: 0.2)])],
            sourceDuration: 5.0)
        #expect(result.peaks[10] == 0.2, "a loud capture survived under a quiet take")
        #expect(result.peaks[11] == 0.2)
        #expect(result.peaks[12] == 0.9, "the capture did not come back after the take")
    }

    @Test("The capture is untouched everywhere no take reaches")
    func captureSurvivesElsewhere() {
        let result = MicrophoneWaveform.overdubbed(
            capture([Float](repeating: 0.4, count: 50)),
            takes: [take([0.9], segments: [OverdubSegment(takeStart: 0, sourceStart: 3.0,
                                                          durationSeconds: 0.1)])],
            sourceDuration: 5.0)
        #expect(result.peaks[0] == 0.4)
        #expect(result.peaks[49] == 0.4)
    }

    @Test("A take split by a cut lands in both places, keeping its own order")
    func splitTakeKeepsItsOrder() {
        // A take spoken across a cut is two segments of one file. Playing the
        // second half first is the failure this catches, and it is inaudible
        // in any assertion that only checks both halves are present.
        let result = MicrophoneWaveform.overdubbed(
            capture([Float](repeating: 0, count: 100)),
            takes: [take([0.3, 0.3, 0.8, 0.8],
                         segments: [
                            OverdubSegment(takeStart: 0, sourceStart: 1.0, durationSeconds: 0.2),
                            OverdubSegment(takeStart: 0.2, sourceStart: 6.0, durationSeconds: 0.2),
                         ])],
            sourceDuration: 10.0)
        #expect(result.peaks[10] == 0.3, "the first half is not at the first place")
        #expect(result.peaks[60] == 0.8, "the second half is not at the second place")
    }

    @Test("A later take wins where two overlap")
    func laterTakeWins() {
        // Recording again over a line you already re-recorded is a fix, and
        // the second attempt is the one you meant — the same precedence
        // `MicrophoneTimeline` gives the audio, so the lane cannot disagree
        // with what plays.
        let result = MicrophoneWaveform.overdubbed(
            capture([Float](repeating: 0, count: 50)),
            takes: [take([0.3, 0.3], segments: [OverdubSegment(takeStart: 0, sourceStart: 1.0,
                                                               durationSeconds: 0.2)]),
                    take([0.7, 0.7], segments: [OverdubSegment(takeStart: 0, sourceStart: 1.0,
                                                               durationSeconds: 0.2)])],
            sourceDuration: 5.0)
        #expect(result.peaks[10] == 0.7, "the earlier take is still drawn over the later one")
    }

    @Test("The lane spans the whole recording, not just the takes")
    func laneSpansTheRecording() {
        // Without the capture's own length the band would end wherever the
        // last take did and look truncated.
        let result = MicrophoneWaveform.overdubbed(
            capture([0.5]),
            takes: [take([0.9], segments: [OverdubSegment(takeStart: 0, sourceStart: 0,
                                                          durationSeconds: 0.1)])],
            sourceDuration: 5.0)
        #expect(result.peaks.count == 50, "got \(result.peaks.count) samples for 5s at 10/s")
    }

    @Test("A segment claiming more audio than the file holds is clipped, not a crash")
    func oversizedSegmentIsClipped() {
        // Both directions: a take cut off at the tail claims more than its
        // file has, and a take that ran on after the footage stopped claims
        // more than the lane has.
        let result = MicrophoneWaveform.overdubbed(
            capture([Float](repeating: 0, count: 50)),
            takes: [take([0.9, 0.9],
                         segments: [OverdubSegment(takeStart: 0, sourceStart: 4.8,
                                                   durationSeconds: 10.0)])],
            sourceDuration: 5.0)
        #expect(result.peaks.count == 50)
        #expect(result.peaks[48] == 0.9)
    }

    @Test("It is named so the timeline and the mix can find it")
    func laneIsNamedMicrophone() {
        // The lane a take draws into is the MICROPHONE's, not a third one.
        // `drawWaveform` matches lanes by name, so a take returned under any
        // other name would be laid out and never drawn.
        let result = MicrophoneWaveform.overdubbed(
            capture([0.1]),
            takes: [take([0.9], segments: [OverdubSegment(takeStart: 0, sourceStart: 0,
                                                          durationSeconds: 0.1)])],
            sourceDuration: 1.0)
        #expect(result.track == "microphone")
        #expect(result.samplesPerSecond == rate)
    }

    @Test("No takes means the capture, unchanged and not copied through a merge")
    func noTakesIsTheCapture() {
        // The overwhelmingly common case. It must be the same object's worth
        // of samples, not a rebuild that could round differently.
        let original = capture([0.1, 0.2, 0.3])
        #expect(MicrophoneWaveform.overdubbed(original, takes: [], sourceDuration: 5.0) == original)
    }

    @Test("A take with no segments leaves the capture alone")
    func emptySegmentsChangeNothing() {
        // A take recorded entirely over footage that has since been cut.
        let original = capture([0.1, 0.2, 0.3])
        let result = MicrophoneWaveform.overdubbed(
            original, takes: [take([0.9], segments: [])], sourceDuration: 0.3)
        #expect(result.peaks == original.peaks)
    }
}
