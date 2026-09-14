// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittExport
@testable import SnittDocument

/// Putting the voiceover's waveform on the capture's clock.
///
/// The timeline maps every pixel column through `KeptRanges` into SOURCE
/// seconds and reads the peak there, so a lane can only be drawn from samples
/// indexed that way. The voiceover file is indexed by its own time — narration
/// recorded over source 30 starts at second 0 of `voiceover.m4a` — so drawing
/// it unmapped would put the narration at the start of the recording.
struct VoiceoverWaveformTests {

    private let rate = 10.0

    /// Peaks that identify their own index, so a misplacement is visible as a
    /// value rather than as "some numbers moved".
    private func ramp(seconds: Double) -> WaveformSamples {
        WaveformSamples(track: "voiceover", samplesPerSecond: rate,
                        peaks: (0..<Int(seconds * rate)).map { Float($0 + 1) / 100 })
    }

    private func track(_ segments: [VoiceoverSegment]) -> VoiceoverTrack {
        VoiceoverTrack(filename: "voiceover.m4a", durationSeconds: 100, segments: segments)
    }

    @Test("Narration lands at the SOURCE time it was spoken over, not at zero")
    func peaksMoveToTheirSourcePosition() {
        // The defect this prevents: a lane drawn from the raw file shows every
        // voiceover starting at the beginning of the recording.
        let subject = VoiceoverWaveform.sourceAligned(
            ramp(seconds: 2),
            track: track([VoiceoverSegment(voiceoverStart: 0, sourceStart: 30,
                                           durationSeconds: 2)]),
            sourceDuration: 60)

        #expect(subject.peaks.count == 600)
        // Second 0 of the FILE is at second 30 of the source.
        #expect(subject.peaks[300] == 0.01)
        #expect(subject.peaks[Int(31 * rate)] == 0.11)
        // And nothing at the start, where the narration is not.
        #expect(subject.peaks[0] == 0)
        #expect(subject.peaks[299] == 0)
    }

    @Test("Silence everywhere the narration does not reach")
    func unnarratedFootageIsSilent() {
        // A lane stretched to fill the width would claim narration over
        // footage that has none, which is worse than an empty band: it looks
        // like data.
        let subject = VoiceoverWaveform.sourceAligned(
            ramp(seconds: 1),
            track: track([VoiceoverSegment(voiceoverStart: 0, sourceStart: 10,
                                           durationSeconds: 1)]),
            sourceDuration: 60)
        let narrated = (100..<110)
        for index in subject.peaks.indices where !narrated.contains(index) {
            #expect(subject.peaks[index] == 0, "sound at \(index), outside the narration")
        }
    }

    @Test("A split voiceover lands in both places, keeping its own order")
    func splitNarrationIsPlacedTwice() {
        // Narration spoken across a cut is two segments over two stretches of
        // footage, and the file is continuous across them. Each half has to
        // land where ITS footage is.
        let subject = VoiceoverWaveform.sourceAligned(
            ramp(seconds: 4),
            track: track([
                VoiceoverSegment(voiceoverStart: 0, sourceStart: 5, durationSeconds: 2),
                VoiceoverSegment(voiceoverStart: 2, sourceStart: 40, durationSeconds: 2),
            ]),
            sourceDuration: 60)
        #expect(subject.peaks[50] == 0.01)              // file 0s  -> source 5s
        #expect(subject.peaks[400] == 0.21)             // file 2s  -> source 40s
        #expect(subject.peaks[200] == 0, "the gap between the halves is not silent")
    }

    @Test("The lane spans the whole recording, not just the narration")
    func laneMatchesTheCaptureLength() {
        // Otherwise the band ends wherever the narration did and reads as a
        // truncated track rather than a quiet one.
        let subject = VoiceoverWaveform.sourceAligned(
            ramp(seconds: 1),
            track: track([VoiceoverSegment(voiceoverStart: 0, sourceStart: 0,
                                           durationSeconds: 1)]),
            sourceDuration: 90)
        #expect(subject.peaks.count == 900)
    }

    @Test("A segment claiming more audio than the file holds is clipped, not a crash")
    func overrunningSegmentIsClipped() {
        // Reachable both ways: a take cut off at the tail leaves segments
        // longer than the recorded audio, and narration that ran on after the
        // footage stopped sits past the capture's end.
        let subject = VoiceoverWaveform.sourceAligned(
            ramp(seconds: 1),
            track: track([VoiceoverSegment(voiceoverStart: 0, sourceStart: 55,
                                           durationSeconds: 30)]),
            sourceDuration: 60)
        #expect(subject.peaks.count == 600)
        #expect(subject.peaks[550] == 0.01)
    }

    @Test("It is named so the timeline and the mix can find it")
    func resultIsNamedVoiceover() {
        // `drawWaveform` looks the lane up by name and the audio mix resolves
        // `TrackState` the same way, so a result carrying the SOURCE
        // waveform's name would be drawn into the microphone's band.
        let subject = VoiceoverWaveform.sourceAligned(
            WaveformSamples(track: "something else", samplesPerSecond: rate, peaks: [1, 1]),
            track: track([VoiceoverSegment(voiceoverStart: 0, sourceStart: 0,
                                           durationSeconds: 0.2)]),
            sourceDuration: 10)
        #expect(subject.track == "voiceover")
        #expect(subject.track == AudioTrackOrder.canonical.last)
    }

    @Test("No segments means a silent lane rather than no lane")
    func emptyTrackIsSilentNotAbsent() {
        let subject = VoiceoverWaveform.sourceAligned(
            ramp(seconds: 2), track: track([]), sourceDuration: 10)
        #expect(subject.peaks.count == 100)
        #expect(subject.peaks.allSatisfy { $0 == 0 })
    }
}
