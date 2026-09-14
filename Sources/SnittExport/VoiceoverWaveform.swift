// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittDocument

/// Placing a voiceover's waveform on the SAME clock as the capture's.
///
/// **Why this exists rather than a second drawing routine.** `TimelineView`
/// draws a waveform by mapping each pixel column through `KeptRanges` into
/// SOURCE seconds and reading the peak there — so every set of samples it can
/// draw has to be indexed by source time. The voiceover's own file is indexed
/// by its own time, which is a different clock: narration recorded over source
/// 30-36 starts at second 0 of `voiceover.m4a`.
///
/// Re-indexing here means the timeline draws the third lane with the code it
/// already has, cuts and zoom included. The alternative — teaching
/// `drawWaveform` a second mapping — is a branch inside the one routine every
/// lane depends on, for the one lane that is different.
public enum VoiceoverWaveform {

    /// `voiceover`'s peaks, re-indexed into the capture's source timeline.
    ///
    /// Silence everywhere the narration does not reach, which is the truth: a
    /// voiceover covers part of a recording, and a lane that stretched it to
    /// fill the width would claim narration over footage that has none.
    ///
    /// - Parameter sourceDuration: the CAPTURE's length, so the result spans
    ///   the same range as the tracks beside it. Without it the lane would end
    ///   wherever the narration did and the band would look truncated.
    public static func sourceAligned(_ voiceover: WaveformSamples,
                                     track: VoiceoverTrack,
                                     sourceDuration: Double) -> WaveformSamples {
        let rate = voiceover.samplesPerSecond
        guard rate > 0, sourceDuration > 0 else {
            return WaveformSamples(track: "voiceover", samplesPerSecond: rate, peaks: [])
        }
        var peaks = [Float](repeating: 0, count: Int((sourceDuration * rate).rounded(.up)))
        guard !peaks.isEmpty else {
            return WaveformSamples(track: "voiceover", samplesPerSecond: rate, peaks: [])
        }

        for segment in track.segments {
            let count = Int((segment.durationSeconds * rate).rounded())
            guard count > 0 else { continue }
            let fromBase = Int((segment.voiceoverStart * rate).rounded())
            let toBase = Int((segment.sourceStart * rate).rounded())
            for offset in 0..<count {
                let from = fromBase + offset
                let to = toBase + offset
                // Both bounds checked every iteration rather than the ranges
                // clipped once. A segment can outrun EITHER array: the
                // recorded audio is shorter than its segments claim when a
                // take was cut off at the tail, and a segment can sit past the
                // capture's end when narration ran on after the footage
                // stopped.
                guard from >= 0, from < voiceover.peaks.count,
                      to >= 0, to < peaks.count else { continue }
                // `max`, not assignment: two segments can land on one bucket
                // where a cut falls mid-bucket, and the louder of the two is
                // what that moment sounded like.
                peaks[to] = max(peaks[to], voiceover.peaks[from])
            }
        }
        return WaveformSamples(track: "voiceover", samplesPerSecond: rate, peaks: peaks)
    }
}
