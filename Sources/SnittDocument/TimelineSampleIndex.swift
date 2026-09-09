// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Maps a pixel column's OUTPUT time onto an index into source-time samples.
///
/// This is the join between two clocks and the reason waveforms and filmstrips
/// survive editing for free: samples are taken once against `capture.mov`
/// (source time), while the timeline draws the trimmed result (output time). A
/// cut, a zoom or a scroll changes only which source instant a column shows.
///
/// Pure, so the conversion is testable without an asset, a view, or a decoded
/// frame — the same split that made `CropGeometry` and `TimelineFoldExtent`
/// testable.
public enum TimelineSampleIndex {
    /// The sample index a column at `outputSeconds` should draw, or `nil` when
    /// that column has no source instant behind it.
    ///
    /// `nil` is a real answer, not a failure: an output time past the end of
    /// the trimmed timeline has no source behind it, and drawing the last
    /// sample there instead would smear the final frame's audio across the
    /// empty tail.
    public static func index(forOutputSeconds outputSeconds: Double,
                             keptRanges: [TimeRange],
                             samplesPerSecond: Double,
                             sampleCount: Int) -> Int? {
        guard sampleCount > 0, samplesPerSecond > 0, outputSeconds >= 0 else { return nil }
        guard let source = TimeRangeMapping.sourceTime(ofTrimmedTime: outputSeconds,
                                                       keptRanges: keptRanges) else { return nil }
        let index = Int(source * samplesPerSecond)
        // Clamped at the top rather than returning nil: the last bucket is
        // partial, so a source time inside the final fraction of a second
        // legitimately rounds one past the end.
        guard index >= 0 else { return nil }
        return min(index, sampleCount - 1)
    }
}
