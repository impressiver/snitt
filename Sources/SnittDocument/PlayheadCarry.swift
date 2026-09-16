// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Where the playhead should land after an edit rebuilds the composition.
///
/// `AVPlayer.replaceCurrentItem` starts the new item at zero, so every rebuild
/// sent the playhead back to the beginning — after a cut, after a marker,
/// after recording a take. Nothing said so, and the failure it caused was not
/// the jump: it was that the NEXT take read the playhead to decide where it
/// had been spoken, got 0, and claimed to cover the opening seconds of the
/// recording. The words it was supposed to replace then survived, because they
/// were nowhere near what the take said it covered.
///
/// Carried through SOURCE time rather than kept as an output number. Output
/// time means different footage before and after an edit — a cut above the
/// playhead moves everything below it — so holding the number would hold the
/// wrong moment precisely when the edit was one that mattered.
public enum PlayheadCarry {

    /// `outputTime` under `before`, expressed in the timeline `after` leaves.
    ///
    /// Nil when that moment is gone: the playhead was sitting on footage the
    /// edit removed. The caller decides what to do about it — this refuses to
    /// invent a position, because the honest answers (the cut's near edge, the
    /// start) are a presentation choice rather than arithmetic.
    public static func carried(outputTime: Double,
                               before: [TimeRange],
                               after: [TimeRange]) -> Double? {
        guard let source = TimeRangeMapping.sourceTime(ofTrimmedTime: outputTime,
                                                       keptRanges: before)
        else { return nil }
        return TimeRangeMapping.trimmedTime(of: source, keptRanges: after)
    }

    /// `carried`, falling back to the nearest moment that still exists.
    ///
    /// Clamped to the new duration rather than reset to zero. A playhead that
    /// jumps to the start after an edit loses the place you were working in,
    /// which is the whole complaint; landing at the end of what survives keeps
    /// you next to it.
    public static func carriedOrNearest(outputTime: Double,
                                        before: [TimeRange],
                                        after: [TimeRange],
                                        newDuration: Double) -> Double {
        if let exact = carried(outputTime: outputTime, before: before, after: after) {
            return min(max(0, exact), max(0, newDuration))
        }
        return min(max(0, outputTime), max(0, newDuration))
    }
}
