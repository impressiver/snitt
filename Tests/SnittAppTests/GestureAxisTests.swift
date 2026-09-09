// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
@testable import SnittApp
import SnittDocument
import Testing

/// M5f whole-branch review, Critical findings C1 and C2: interaction must be
/// interpreted on the axis the user is looking at.
///
/// Before this fix `TimelineView` ran gestures through a second geometry
/// (`gestureGeometry`) built over the recording's own uncut length, while
/// every pixel on screen was drawn by `geometry` over
/// `Timebase.outputDuration`. The two agree exactly while nothing has been
/// cut — which is why every pre-existing gesture test in this target passed
/// with `cuts: []` — and diverge the instant anything has. This file is the
/// cut-bearing half nothing covered.
///
/// The fixture below is the review's own constructed case, and the numbers
/// in each test are its measurements: a 10s recording, one 2s cut at [3,5],
/// an 800px view. Drawing runs at 100px per OUTPUT second; the deleted
/// gesture axis ran at 80px per SOURCE second.
///
/// Two properties are asserted WITHOUT reaching into the view's private
/// geometry, because a test that recomputes the geometry it is checking
/// proves only that two copies of the same arithmetic agree:
///
///  - `onScrub`/`onSelect` report a SOURCE time, and the test converts it
///    with a `Timebase` built from the same duration and cuts the view was
///    handed — public arithmetic pinned in `TimebaseTests`.
///  - Where the DRAWING axis has to be the oracle, the test asks the one
///    interaction the review certified as already correct: a marker drag
///    (`onMoveMarker`) reports `geometry.outputTime(atX:)` verbatim, so
///    dragging a marker to a pixel is a public read of where the view
///    thinks that pixel is. `axesAgreeAtEveryZoomLevel` is built on that.
@MainActor
struct GestureAxisTests {
    private static let sourceDuration = 10.0
    private static let width = 800.0
    /// The review's fixture: one 2s cut, leaving 8s of output in 800px.
    private static func fixtureCut() -> Cut {
        Cut(range: TimeRange(start: 3, end: 5))
    }

    private static func timebase(cuts: [Cut]) -> Timebase {
        Timebase(sourceDuration: sourceDuration, edl: EditDecisionList(cuts: cuts))
    }

    private static func makeView(cuts: [Cut], jumpPoints: [JumpPoint] = [],
                                 playhead: Double = 0, height: Double = 40) -> TimelineView {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.update(duration: sourceDuration, cuts: cuts, markerPoints: jumpPoints,
                    playhead: playhead)
        return view
    }

    /// `NSEvent` locations are WINDOW coordinates (bottom-up) while
    /// `TimelineView.isFlipped` is true, and `mouseDown`'s own
    /// `convert(_:from:)` flips between them even with no window attached.
    /// Same helper, same reason, as `TrackLayoutTimelineViewTests`.
    private func windowY(forViewY viewY: Double, height: Double) -> CGFloat {
        CGFloat(height - viewY)
    }

    // MARK: - C2: the defect the fixed-source axis was adopted to prevent

    @Test("The same pixel drag twice, with a cut in between, removes a SECOND span")
    func repeatedDragOverTheSamePixelsCutsTwice() throws {
        // M4b whole-branch review, Critical #1, stated directly: "a second
        // trim silently did nothing." The fixed-source gesture axis was
        // adopted citing that finding and REPRODUCED it — dragging pixels
        // 240..400 twice yielded source 3.0...5.0 both times, appended a
        // duplicate `Cut`, and left `outputDuration` at 8.0.
        //
        // On the output axis the same pixels after the first cut resolve to
        // output 2.4...4.0 — fresh, KEPT footage — so the second cut is
        // real. This mirrors `EditorTimelineState.cutSelection()` exactly
        // (append `Cut(range:)`, re-feed the view) without a compositor, so
        // the property is asserted against `Timebase.outputDuration` rather
        // than a player's cached copy of it.
        var edl = EditDecisionList()
        let view = Self.makeView(cuts: edl.cuts)
        var selected: Selection?
        view.onSelect = { selected = $0 }

        func dragOverTheSamePixels() throws -> Selection {
            selected = nil
            view.mouseDown(with: .synthetic(at: NSPoint(x: 240, y: 20), in: view))
            view.mouseDragged(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
            view.mouseUp(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
            return try #require(selected)
        }

        let first = try dragOverTheSamePixels()
        #expect(abs(first.range.start - 3.0) < 0.01)
        #expect(abs(first.range.end - 5.0) < 0.01)
        edl.cuts.append(Cut(range: first.range))
        #expect(abs(Self.timebase(cuts: edl.cuts).outputDuration - 8.0) < 0.01)
        view.update(duration: Self.sourceDuration, cuts: edl.cuts, markerPoints: [], playhead: 0)

        let second = try dragOverTheSamePixels()
        // The SAME pixels, now over a shorter timeline: output 2.4...4.0,
        // which is source 2.4...6.0 (the removed 3...5 sits inside it).
        #expect(abs(second.range.start - 2.4) < 0.01)
        #expect(abs(second.range.end - 6.0) < 0.01)
        edl.cuts.append(Cut(range: second.range))

        // The property that matters, independent of the exact numbers
        // above: the second deliberate drag removed something. Kept is now
        // [0,2.4] + [6,10] = 6.4s.
        let after = Self.timebase(cuts: edl.cuts).outputDuration
        #expect(after < 8.0, "a second deliberate drag over the same pixels must remove more footage")
        #expect(abs(after - 6.4) < 0.01)
    }

    // MARK: - C1: scrub, selection and snapping with a cut present

    @Test("A click resolves to the instant its pixel actually shows")
    func clickResolvesToTheInstantUnderTheCursor() throws {
        // x=400 is the middle of an 800px view showing 8s of output —
        // output 4.0, which is SOURCE 6.0 with [3,5] removed. The deleted
        // fixed-source axis answered 5.0 and drew the playhead at x=300,
        // 100px (12.5% of the view) from where it was clicked.
        let view = Self.makeView(cuts: [Self.fixtureCut()])
        var scrubbed: Double?
        view.onScrub = { scrubbed = $0 }

        view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))

        let source = try #require(scrubbed)
        #expect(abs(source - 6.0) < 0.01)
    }

    @Test("A click's reported time maps back to the pixel that was clicked, with a cut present")
    func clickRoundTripsBackToItsOwnPixel() throws {
        // The review's "adjacent property to add with the fix": nothing
        // today would catch a regression, because every other scrub test
        // uses `cuts: []`, where the two axes coincide and the bug is
        // invisible. Converted the way `EditorTimelineState.onScrub`
        // converts it, a click must land back within a pixel of itself.
        let cut = Self.fixtureCut()
        let view = Self.makeView(cuts: [cut])
        let timebase = Self.timebase(cuts: [cut])
        let geometry = TimelineGeometry(width: Self.width, timebase: timebase)
        var scrubbed: Double?
        view.onScrub = { scrubbed = $0 }

        for x in [80.0, 200.0, 400.0, 640.0, 760.0] {
            scrubbed = nil
            view.mouseDown(with: .synthetic(at: NSPoint(x: x, y: 20), in: view))
            view.mouseUp(with: .synthetic(at: NSPoint(x: x, y: 20), in: view))
            let source = try #require(scrubbed, "no scrub reported at x=\(x)")
            let backToOutput = try #require(
                TimeRangeMapping.nearestTrimmedTime(toSourceTime: source,
                                                    keptRanges: KeptRanges.compute(
                                                        duration: Self.sourceDuration,
                                                        cuts: [cut.range])))
            let backToX = geometry.x(atOutput: OutputTime(backToOutput))
            #expect(abs(backToX - x) < 1.0,
                    "click at x=\(x) resolved to source \(source), drawn back at x=\(backToX)")
        }
    }

    @Test("A drag with a cut present selects the footage its pixels point at")
    func dragSelectsTheFootageUnderThePixels() throws {
        // The review's measurement: dragging 400 -> 600 removed source
        // 5.0...7.5 while the pixels pointed at source 6.0...8.0 — the cut
        // removed footage other than the footage selected on screen.
        let view = Self.makeView(cuts: [Self.fixtureCut()])
        var selected: Selection?
        view.onSelect = { selected = $0 }

        view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 600, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 600, y: 20), in: view))

        let selection = try #require(selected)
        #expect(abs(selection.range.start - 6.0) < 0.01)
        #expect(abs(selection.range.end - 8.0) < 0.01)
    }

    @Test("A cut edge's snap target sits at the fold that is actually drawn")
    func snapTargetForACutEdgeIsTheDrawnFold() throws {
        // The fold for [3,5] draws at OUTPUT 3.0 — x=300. The deleted
        // gesture axis put that cut's snap targets at x=240 and x=400
        // (source 3.0 and 5.0 at 80px/s), so a drag ending 8px right of the
        // drawn fold snapped to nothing.
        let cut = Self.fixtureCut()
        let view = Self.makeView(cuts: [cut])
        var selected: Selection?
        view.onSelect = { selected = $0 }

        view.mouseDown(with: .synthetic(at: NSPoint(x: 100, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 304, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 304, y: 20), in: view))

        let selection = try #require(selected)
        // Output 3.0 — the single instant the fold collapses to — is source
        // 5.0, the cut's far edge: the first frame still kept after it.
        // Unsnapped, x=304 would report source 5.04.
        #expect(abs(selection.range.end - 5.0) < 0.001)

        // A cut contributes ONE candidate, not two. `cut.range.end` is
        // source 5.0, and a candidate list built from raw `Cut` edges
        // treated as output instants would put a second target at output
        // 5.0 — x=500 — where nothing is drawn at all. This fixture cannot
        // discriminate that at the cut's START (with nothing cut before it,
        // source 3.0 and the fold's output 3.0 are the same number), so the
        // discriminating half is here: x=502 must NOT snap.
        selected = nil
        view.mouseDown(with: .synthetic(at: NSPoint(x: 100, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 502, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 502, y: 20), in: view))
        let unsnapped = try #require(selected)
        #expect(abs(unsnapped.range.end - 7.02) < 0.001)
        #expect(abs(unsnapped.range.end - 7.0) > 0.001,
                "a raw cut edge became a snap target at a pixel nothing is drawn at")
    }

    @Test("A marker's snap target sits at the marker that is actually drawn")
    func snapTargetForAMarkerIsTheDrawnMarker() throws {
        // A marker at OUTPUT 6.0 draws at x=600 (`geometry.x(atOutput:)`,
        // the same call `draw` makes). The deleted gesture axis converted it
        // to SOURCE 8.0 first and compared at 80px/s, putting its snap
        // target at x=640 — 40px from the glyph it belongs to.
        let cut = Self.fixtureCut()
        let marker = JumpPoint(timeSeconds: 6.0, label: "m")
        let view = Self.makeView(cuts: [cut], jumpPoints: [marker])
        var selected: Selection?
        view.onSelect = { selected = $0 }

        view.mouseDown(with: .synthetic(at: NSPoint(x: 100, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 602, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 602, y: 20), in: view))

        let selection = try #require(selected)
        // Output 6.0 is source 8.0 with [3,5] removed. Unsnapped, x=602
        // would report source 8.02.
        #expect(abs(selection.range.end - 8.0) < 0.001)
    }

    @Test("Hit-testing and drawing resolve a fold to the same pixel even when it is scrolled out of view")
    func foldHitAndDrawingAgreeWhenScrolledOutOfView() throws {
        // `TimelineGeometry.x(atOutput:)` CLAMPS an out-of-viewport instant
        // to 0 or `width` rather than extrapolating — and `draw` calls
        // exactly that, so a fold scrolled off the left really is drawn as
        // a red line piled at x=0. `foldHit(atX:)` and
        // `snappedOutputTime(atX:)` call the same thing, so a click there
        // lands on the line the person can see.
        //
        // This is pinned because the obvious "tidy-up" — filtering
        // out-of-viewport candidates out of hit-testing and snapping — makes
        // interaction disagree with drawing, which is C1 in miniature. If
        // the piling itself should stop (a DRAWING question, adjacent to the
        // review's undetermined item about `visibleOffset`'s upper clamp),
        // the change belongs in `draw`/`TimelineGeometry`, and this test is
        // what will say so.
        //
        // 20s recording, one cut at [10,12], zoomed 4x anchored on a
        // playhead near the end — the fold sits far off the left edge.
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let sourceDuration = 20.0
        let timebase = Timebase(sourceDuration: sourceDuration, edl: EditDecisionList(cuts: [cut]))
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 40))
        view.update(duration: sourceDuration, cuts: [cut], markerPoints: [], playhead: 17.0)
        for _ in 0..<2 { view.zoomIn() }   // 4x, anchored on the playhead

        // The geometry the view is now on — the same `zoomed(by:anchoredAt:)`
        // call `rebuildGeometry` makes, reproduced through public API.
        let geometry = TimelineGeometry(width: Self.width, timebase: timebase)
            .zoomed(by: 4, anchoredAt: OutputTime(17.0))
        // The premise: the fold really is off the left edge, and really is
        // drawn at x=0 anyway.
        #expect(timebase.foldPosition(for: cut).seconds < geometry.visibleOffset)
        #expect(geometry.x(atFold: cut) == 0)

        var toggled: UUID?
        var scrubbed: Double?
        view.onToggleExpansion = { toggled = $0 }
        view.onScrub = { scrubbed = $0 }
        view.mouseDown(with: .synthetic(at: NSPoint(x: 3, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 3, y: 20), in: view))

        #expect(toggled == cut.id)
        #expect(scrubbed == nil)
    }

    // MARK: - F3: zoom, which the deleted doc comments claimed kept the two axes agreeing

    @Test("The gesture and drawing axes agree at every zoom level, with a cut present")
    func axesAgreeAtEveryZoomLevel() throws {
        // F3: `TimelineView`'s type doc and `gestureGeometry`'s own doc both
        // asserted that applying the same zoom factor to both geometries
        // kept them "in visual agreement". Measured, it did the opposite —
        // 1x/2x/4x/8x drifted -100/-200/-400/-400 px — because the same
        // NUMBER applied to two different clocks is not the same zoom.
        //
        // The DRAWING axis is read here through the one interaction the
        // review certified as already correct: `onMoveMarker` reports
        // `geometry.outputTime(atX:)` verbatim. A marker parked at output
        // 0.0, with the playhead (and therefore every `zoomIn()` anchor)
        // also at 0.0, stays drawn at x=0 at every zoom level, so it can be
        // picked up and dropped on the pixel under test.
        let cut = Self.fixtureCut()
        let height = 56.0
        let marker = JumpPoint(timeSeconds: 0.0, label: "anchor")
        let timebase = Self.timebase(cuts: [cut])

        for zoomSteps in 0...3 {
            let view = Self.makeView(cuts: [cut], jumpPoints: [marker], height: height)
            for _ in 0..<zoomSteps { view.zoomIn() }

            var movedToOutput: Double?
            var scrubbed: Double?
            view.onMoveMarker = { _, output in movedToOutput = output }
            view.onScrub = { scrubbed = $0 }

            // Drawing axis: drag the marker from x=0 to x=400 in its own
            // lane and read back the OUTPUT time the view believes x=400 is.
            let laneY = windowY(forViewY: 5, height: height)
            view.mouseDown(with: .synthetic(at: NSPoint(x: 0, y: laneY), in: view))
            view.mouseDragged(with: .synthetic(at: NSPoint(x: 400, y: laneY), in: view))
            view.mouseUp(with: .synthetic(at: NSPoint(x: 400, y: laneY), in: view))
            let output = try #require(movedToOutput, "no marker move at zoom step \(zoomSteps)")

            // Gesture axis: click the SAME pixel on the track below.
            view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
            view.mouseUp(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
            let source = try #require(scrubbed, "no scrub at zoom step \(zoomSteps)")

            let expected = try #require(timebase.sourceTime(forOutput: OutputTime(output))?.seconds)
            #expect(abs(source - expected) < 0.01,
                    "at zoom step \(zoomSteps): x=400 is drawn as output \(output), source \(expected); a click there reported source \(source)")
        }
    }
}

// MARK: - Expanded folds insert space into the SHARED axis

/// A drag after an expanded fold must select the instant under the cursor.
///
/// This is the guard for the change that made expanded folds reflow. Drawing
/// inserts the cut's source length into the axis so the playhead jumps the band
/// instead of crawling through removed footage — and if hit-testing did not
/// insert the same space, every click after an expanded fold would land at a
/// different instant than the one drawn there. That is M4b's Critical #1, which
/// is why it is tested here rather than beside the geometry.
@MainActor
struct ExpandedFoldAxisTests {
    @Test("Expanding a fold moves where a later instant is DRAWN and HIT alike")
    func expansionMovesBothAxesTogether() throws {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        var selected: Selection?
        view.onSelect = { selected = $0 }
        // 20s source, 4s cut at 5...9 → 16s output, fold at output 5.
        let cut = Cut(range: TimeRange(start: 5, end: 9))
        view.update(duration: 20, cuts: [cut], markerPoints: [], playhead: 0)

        // Where output 10 is drawn, collapsed.
        let collapsedX = view.xForTesting(outputSeconds: 10)

        view.update(duration: 20, cuts: [cut], markerPoints: [], playhead: 0,
                    expandedCutIDs: [cut.id])
        let expandedX = view.xForTesting(outputSeconds: 10)
        #expect(expandedX != collapsedX, "expanding the fold did not move later content")

        // The decisive part: a click at the NEW position must resolve to the
        // same instant it is drawn at. An implementation that inserts space
        // when drawing but not when hit-testing fails here while every drawing
        // assertion above still passes.
        var scrubbed: Double?
        view.onScrub = { scrubbed = $0 }
        view.mouseDown(with: .synthetic(at: NSPoint(x: expandedX, y: 40), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: expandedX, y: 40), in: view))
        let landed = try #require(scrubbed)
        // onScrub reports SOURCE time; output 10 is source 14 past the 4s cut.
        #expect(abs(landed - 14) < 0.3, "click landed at source \(landed), expected ~14")
        _ = selected
    }
}
