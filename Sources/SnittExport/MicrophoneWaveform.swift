// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittDocument

/// The microphone lane's waveform, once takes have been recorded over it (D102).
///
/// **Why this exists rather than a second drawing routine.** `TimelineView`
/// draws a waveform by mapping each pixel column through `KeptRanges` into
/// SOURCE seconds and reading the peak there — so every set of samples it can
/// draw has to be indexed by source time. A take's own file is indexed by its
/// own time, which is a different clock: audio recorded over source 30-36
/// starts at second 0 of its file.
///
/// Re-indexing here means the timeline draws the microphone with the code it
/// already has, cuts and zoom included. The alternative — teaching
/// `drawWaveform` a second mapping — is a branch inside the one routine every
/// lane depends on.
///
/// It REPLACES rather than mixes, because that is what the audio does. Under
/// D93 this produced a separate lane and took `max` of the two, since both
/// were audible at once; a take is heard *instead of* what was captured, and a
/// waveform showing the louder of the two would draw audio nobody will hear.
/// Looking at the lane is how you find the take you just recorded, so drawing
/// it accurately is the whole point.
public enum MicrophoneWaveform {

    /// One take's peaks, with the placement that says where they belong.
    public struct Take {
        public var overdub: Overdub
        public var samples: WaveformSamples

        public init(overdub: Overdub, samples: WaveformSamples) {
            self.overdub = overdub
            self.samples = samples
        }
    }

    /// `capture`'s microphone peaks with every take written over them, in
    /// SOURCE time.
    ///
    /// Takes are applied in order, so a later one overwrites an earlier one
    /// where they overlap — the same precedence `MicrophoneTimeline` gives the
    /// audio itself, and the lane would be lying if the two disagreed.
    ///
    /// - Parameter sourceDuration: the CAPTURE's length, so the result spans
    ///   the same range as the tracks beside it. Without it the lane would end
    ///   wherever the last take did and the band would look truncated.
    public static func overdubbed(_ capture: WaveformSamples,
                                  takes: [Take],
                                  sourceDuration: Double) -> WaveformSamples {
        let rate = capture.samplesPerSecond
        guard rate > 0, sourceDuration > 0 else { return capture }
        guard !takes.isEmpty else { return capture }

        // Sized from the CAPTURE's own length, padded with silence rather than
        // truncated: a take that ran on past the end of the footage has
        // nowhere on this lane to be drawn, and stretching the lane to fit it
        // would claim microphone over frames that do not exist.
        var peaks = capture.peaks
        let wanted = Int((sourceDuration * rate).rounded(.up))
        if peaks.count < wanted { peaks += [Float](repeating: 0, count: wanted - peaks.count) }
        guard !peaks.isEmpty else { return capture }

        for take in takes {
            for segment in take.overdub.segments {
                let count = Int((segment.durationSeconds * rate).rounded())
                guard count > 0 else { continue }
                let fromBase = Int((segment.takeStart * rate).rounded())
                let toBase = Int((segment.sourceStart * rate).rounded())
                for offset in 0..<count {
                    let from = fromBase + offset
                    let to = toBase + offset
                    // Both bounds checked every iteration rather than the
                    // ranges clipped once. A segment can outrun EITHER array:
                    // the recorded audio is shorter than its segments claim
                    // when a take was cut off at the tail, and a segment can
                    // sit past the capture's end when a take ran on after the
                    // footage stopped.
                    guard from >= 0, from < take.samples.peaks.count,
                          to >= 0, to < peaks.count else { continue }
                    // ASSIGNMENT, not `max`. The take is what that moment
                    // sounds like now; keeping the louder of the two would
                    // draw captured audio the export has replaced.
                    peaks[to] = take.samples.peaks[from]
                }
            }
        }
        return WaveformSamples(track: "microphone", samplesPerSecond: rate, peaks: peaks)
    }
}
