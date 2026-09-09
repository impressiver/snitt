// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
@testable import SnittDocument

struct TrimGestureTests {
    /// An arbitrary but representative threshold for tests that aren't
    /// exercising the threshold itself.
    private static let threshold = 0.05

    @Test("A forward drag produces the range it covered")
    func forwardDragProducesRange() {
        var g = TrimGesture()
        g.began(atTime: 2.0)
        g.moved(toTime: 5.0)
        let range = g.ended(atTime: 5.0, minimumSeconds: Self.threshold)
        #expect(range == TimeRange(start: 2.0, end: 5.0))
    }

    @Test("A backwards drag is normalised, not inverted")
    func backwardsDragIsNormalised() {
        // Dragging right-to-left is as natural as left-to-right. EditDecisionList
        // assumes start <= end, so an inverted range silently cuts nothing —
        // the user drags, sees no change, and has no idea why.
        var g = TrimGesture()
        g.began(atTime: 8.0)
        g.moved(toTime: 3.0)
        let range = g.ended(atTime: 3.0, minimumSeconds: Self.threshold)
        #expect(range == TimeRange(start: 3.0, end: 8.0))
    }

    @Test("A click is not a zero-length cut")
    func clickProducesNoCut() {
        // Clicking to seek is the most common timeline interaction. An
        // implementation that returns a range whenever a drag ends fills the EDL
        // with zero-length cuts, one per click.
        var g = TrimGesture()
        g.began(atTime: 4.0)
        let range = g.ended(atTime: 4.0, minimumSeconds: Self.threshold)
        #expect(range == nil)
    }

    @Test("Ending without beginning yields nothing")
    func endWithoutBeginYieldsNothing() {
        var g = TrimGesture()
        #expect(g.ended(atTime: 3.0, minimumSeconds: Self.threshold) == nil)
    }

    @Test("A drag in progress previews the range it would cut")
    func draggingPreviewsRange() {
        // The view needs to draw the pending cut while the mouse is down.
        var g = TrimGesture()
        g.began(atTime: 2.0)
        g.moved(toTime: 6.0)
        #expect(g.previewRange == TimeRange(start: 2.0, end: 6.0))
        // Discriminating against a preview that only appears after the drag
        // ends, which is a preview of nothing.
        #expect(g.phase != .idle)
    }

    @Test("A zero-length range is not a cut even at a zero threshold")
    func zeroLengthRangeIsNeverACutEvenAtZeroThreshold() {
        // M4b whole-branch review, Minor finding #4: a zero-width
        // `TimelineView` computes `minimumDragSeconds == 0` (its geometry
        // clamps to zero at zero width), and `ended`'s old
        // `length >= minimumSeconds` check alone would let `0 >= 0` through
        // — firing a zero-length trim on every click. Guarding `length > 0`
        // is exactly what stops that; this pins the fix at the `TrimGesture`
        // level, independent of the view.
        var g = TrimGesture()
        g.began(atTime: 4.0)
        let range = g.ended(atTime: 4.0, minimumSeconds: 0)
        #expect(range == nil)
    }

    @Test("The same pixel jitter is a no-op at very different recording lengths")
    func samePixelJitterYieldsNoCutRegardlessOfLength() {
        // This is the property a fixed time threshold got wrong (Task 6
        // dispatch): a hand wobbles by roughly the same number of PIXELS on
        // any click, but the same pixel count maps to wildly different
        // amounts of media time depending on the recording's length. A
        // threshold computed in seconds-per-pixel from each timeline's own
        // geometry must absorb the same 2px wobble whether the timeline
        // spans 10 minutes or 5 seconds — a fixed 0.05s constant does not:
        // it swallows a deliberate short cut on the 5s recording (0.05s is
        // ~8px there) while treating it as generous on the 10-minute one
        // (0.05s is far under 1px there).
        let width = 800.0
        // The threshold (3px) is deliberately larger than the actual jitter
        // (2px) it must absorb — a threshold computed from an equal pixel
        // count would sit exactly at the boundary and pass on `>=`, proving
        // nothing about whether the conversion tracks geometry correctly.
        let thresholdPixels = 3.0
        let wobblePixels = 2.0

        // No cuts in either geometry — this test is about the pixel/seconds
        // scale tracking a recording's length, not about `Timebase`'s
        // source/output distinction, so `outputTime(atX:)` is the identity
        // on source time here and stands in for the old `time(atX:)`.
        let longGeometry = TimelineGeometry(
            width: width, timebase: Timebase(sourceDuration: 600, edl: EditDecisionList())) // 10 minutes
        let shortGeometry = TimelineGeometry(
            width: width, timebase: Timebase(sourceDuration: 5, edl: EditDecisionList()))  // 5 seconds

        for geometry in [longGeometry, shortGeometry] {
            let thresholdSeconds = geometry.outputTime(atX: thresholdPixels).seconds
                - geometry.outputTime(atX: 0).seconds
            let startX = 400.0
            let jitteredX = startX + wobblePixels
            var g = TrimGesture()
            g.began(atTime: geometry.outputTime(atX: startX).seconds)
            g.moved(toTime: geometry.outputTime(atX: jitteredX).seconds)
            let range = g.ended(atTime: geometry.outputTime(atX: jitteredX).seconds,
                                minimumSeconds: thresholdSeconds)
            #expect(range == nil)
        }
    }
}
