import Testing
@testable import SnittDocument

/// M5f Task 8: the task the first draft of this milestone missed entirely —
/// none of its ten tasks changed pixels-per-second. `TrimGesture.ended`'s own
/// doc comment names the bottleneck this closes: "a ten-minute recording at
/// 800px is ~0.75s/pixel… a deliberate short cut is silently swallowed."
///
/// Two properties matter here, and each has its own test below:
///
/// 1. The anchor must not move. `zoomKeepsTheAnchorFixed` asserts both the
///    scale change AND the anchor's own fixed pixel — a zoom that only
///    rescales without holding the anchor still is what makes a timeline
///    feel like it is "fighting" whoever is dragging it, and would pass a
///    test that checked scale alone.
/// 2. Snapping tolerance is in pixels, not seconds — pinned at the
///    `TimelineView` level (`TimelineViewTests.swift`, SnittApp), since that
///    is where markers/cut-edges/the playhead actually exist to snap to;
///    this file only covers the pure geometry `TimelineView`'s snapping
///    builds on.
@Suite("TimelineGeometry zoom")
struct TimelineZoomTests {
    @Test("Zooming changes pixels-per-second, and the anchor stays put")
    func zoomKeepsTheAnchorFixed() {
        let base = Timebase(sourceDuration: 600, edl: EditDecisionList(cuts: []))
        var geometry = TimelineGeometry(width: 800, timebase: base)
        #expect(abs(geometry.pixelsPerSecond - 800.0 / 600.0) < 1e-9)

        let anchor = OutputTime(300)
        let xBefore = geometry.x(atOutput: anchor)
        geometry = geometry.zoomed(by: 4, anchoredAt: anchor)

        #expect(abs(geometry.pixelsPerSecond - 4 * 800.0 / 600.0) < 1e-9)
        // The anchor must not move. A zoom that changes scale but slides content
        // under the cursor is what people describe as "fighting the timeline" —
        // and it passes any test that only checks the scale.
        #expect(abs(geometry.x(atOutput: anchor) - xBefore) < 0.5)
    }

    @Test("A cut shorter than one pixel at 1x is placeable when zoomed in")
    func shortCutSurvivesZoom() {
        let base = Timebase(sourceDuration: 600, edl: EditDecisionList(cuts: []))
        let wide = TimelineGeometry(width: 800, timebase: base)
        #expect(wide.duration(ofPixels: 1) > 0.5)   // TrimGesture's stated problem
        let zoomed = wide.zoomed(by: 32, anchoredAt: OutputTime(300))
        #expect(zoomed.duration(ofPixels: 1) < 0.05)
    }

    @Test("Zooming in repeatedly compounds relative to the CURRENT scale, not the original")
    func repeatedZoomCompoundsRelatively() {
        // A plausible wrong `zoomed(by:anchoredAt:)` multiplies the factor
        // against the ORIGINAL (unzoomed) `pixelsPerSecond` captured once,
        // rather than `self.pixelsPerSecond` — indistinguishable from the
        // correct implementation after a SINGLE zoom call, since both agree
        // there, but wrong the moment a second zoom chains onto the first
        // (a scroll wheel firing several small deltas, in practice).
        let base = Timebase(sourceDuration: 600, edl: EditDecisionList(cuts: []))
        let geometry = TimelineGeometry(width: 800, timebase: base)
        let oncePerTwo = geometry.zoomed(by: 2, anchoredAt: OutputTime(300))
        let twicePerTwo = oncePerTwo.zoomed(by: 2, anchoredAt: OutputTime(300))
        #expect(abs(twicePerTwo.pixelsPerSecond - 4 * geometry.pixelsPerSecond) < 1e-9)
    }

    @Test("A non-positive zoom factor is a no-op rather than a corrupted scale")
    func nonPositiveZoomFactorIsANoOp() {
        // A plausible wrong implementation has no guard at all: `factor`
        // multiplies straight through, and a negative one silently produces
        // a NEGATIVE `pixelsPerSecond` — every later pixel maps backwards —
        // rather than leaving the geometry as it found it.
        let base = Timebase(sourceDuration: 600, edl: EditDecisionList(cuts: []))
        let geometry = TimelineGeometry(width: 800, timebase: base)
        let unchanged = geometry.zoomed(by: -1, anchoredAt: OutputTime(300))
        #expect(unchanged.pixelsPerSecond == geometry.pixelsPerSecond)
        #expect(unchanged.visibleOffset == geometry.visibleOffset)
    }
}
