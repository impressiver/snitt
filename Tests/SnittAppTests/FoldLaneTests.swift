// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp
@testable import SnittDocument

/// How a click resolves now that cuts have no lane (rev 5, W11).
///
/// **This file used to test the opposite**, and the reversal is worth keeping
/// visible rather than quietly rewriting. Rev 4 gave folds a 24pt lane and
/// y-gated their hits to it, because an ungated full-height hit swallowed
/// clicks meant for every lane below. The product owner then ruled that cuts
/// do not belong in a lane at all — a cut collapses the entire timeline, so
/// drawing it as one strip among others was the picture disagreeing with the
/// model.
///
/// Deleting the gate as that directive implied was *measured* before it was
/// believed, and it failed: with the gate gone, a single click at a cut's x
/// toggled the fold from the marker, video, audio and transcript lanes and
/// killed scrubbing at that x in all of them — seven assertions in
/// `GestureMatrixTests`.
///
/// So the answer is a PRIORITY rule rather than a region. The precise gesture
/// yields to the lane under the pointer; the coarse gestures keep their reach,
/// because no lane assigns them a meaning at a cut's x:
///
/// | Gesture | Resolves to |
/// |---|---|
/// | single click | the lane under the pointer, always |
/// | double-click | the cut — expand and select — from any lane |
/// | right-click | the cut's Remove Cut menu, from any lane |
@MainActor
struct FoldHitPriorityTests {
    private let width = 800.0
    private let duration = 20.0
    /// Tall enough for marks (24) and a usable video band.
    private let tallEnough = 140.0

    private func makeView(height: Double) -> (TimelineView, Cut, CGFloat) {
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let geometry = TimelineGeometry(
            width: width,
            timebase: Timebase(sourceDuration: duration, edl: EditDecisionList(cuts: [cut])))
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.update(duration: duration, cuts: [cut], markerPoints: [], playhead: 0)
        return (view, cut, CGFloat(geometry.x(atFold: cut)))
    }

    @Test("A cut is hittable at any height, because it is drawn at any height")
    func aCutIsHitAtEveryY() {
        // The x-only hit test is unchanged and stays the shared one: what
        // moved is which GESTURES consult it, not where a cut lives.
        let (view, cut, foldX) = makeView(height: tallEnough)
        for y in [10.0, 36.0, 80.0, 120.0] {
            #expect(view.foldHitForTesting(atX: Double(foldX))?.id == cut.id,
                    "a cut was unreachable at y=\(y)")
        }
    }

    @Test("Single click scrubs at a cut's x, in a tall view and a cramped one")
    func singleClickAlwaysScrubs() {
        // Both heights, because the old behaviour differed between them: a
        // view too short for a fold lane had no gate to apply and fell back to
        // full-height fold hits. That fallback is gone with the lane, so the
        // two heights now behave identically — which is the simplification
        // this ruling buys.
        for height in [tallEnough, 40.0] {
            let (view, _, foldX) = makeView(height: height)
            var toggled: UUID?
            var scrubbed: Double?
            view.onToggleExpansion = { toggled = $0 }
            view.onScrub = { scrubbed = $0 }
            view.mouseDown(with: .synthetic(at: NSPoint(x: foldX, y: height / 2), in: view))
            view.mouseUp(with: .synthetic(at: NSPoint(x: foldX, y: height / 2), in: view))
            #expect(toggled == nil, "a single click toggled a cut in a \(height)pt view")
            #expect(scrubbed != nil, "a single click did not scrub in a \(height)pt view")
        }
    }

    @Test("Double-click still reaches a cut in a cramped view")
    func doubleClickSurvivesAShortView() {
        // The gesture that carries selection now, checked at the height where
        // every pre-existing fold test used to live.
        let (view, cut, foldX) = makeView(height: 40)
        var expanded: UUID?
        view.onExpandAndSelectFold = { expanded = $0 }
        view.mouseDown(with: .synthetic(at: NSPoint(x: foldX, y: 20), in: view, clickCount: 2))
        #expect(expanded == cut.id)
    }

    @Test("The marker lane clears the 24pt target floor at a realistic height")
    func markerLaneMeetsTheFloor() {
        // Unrelated to cuts, and kept: shipped at `min(14.0, …)` while markers
        // are draggable, against WCAG 2.5.8 AA's 24×24 enforceable minimum.
        // Read from the VIEW, not from a height this test computed itself — an
        // earlier version asserted on its own arithmetic and a mutant that
        // reverted `markerTrackHeight` to 14 survived it.
        let (view, _, _) = makeView(height: tallEnough)
        #expect(view.markerTrackHeightForTesting >= 24)
    }
}
