import Testing
@testable import SnittDocument

@Suite("TimelineGeometry")
struct TimelineGeometryTests {
    @Test("Time and x round-trip")
    func timeAndXRoundTrip() {
        let g = TimelineGeometry(width: 800, duration: 20)
        for t in [0.0, 3.7, 10.0, 19.99, 20.0] {
            #expect(abs(g.time(atX: g.x(atTime: t)) - t) < 0.001)
        }
    }

    @Test("The ends map to the ends")
    func endsMapToEnds() {
        let g = TimelineGeometry(width: 800, duration: 20)
        #expect(g.x(atTime: 0) == 0)
        #expect(g.x(atTime: 20) == 800)
        #expect(g.time(atX: 0) == 0)
        #expect(abs(g.time(atX: 800) - 20) < 0.001)
    }

    @Test("Positions outside the view clamp instead of extrapolating")
    func outOfRangeClamps() {
        let g = TimelineGeometry(width: 800, duration: 20)
        // A drag can leave the view; extrapolating gives a negative time or one
        // past the end, and an EDL cut built from it is nonsense.
        #expect(g.time(atX: -50) == 0)
        #expect(abs(g.time(atX: 900) - 20) < 0.001)
        #expect(g.x(atTime: -5) == 0)
        #expect(g.x(atTime: 25) == 800)
    }

    @Test("A zero-width or zero-duration timeline yields no NaN")
    func degenerateGeometryIsFinite() {
        // A view gets laid out at zero width before its first real layout pass,
        // and a bundle can be a fraction of a second long. Division by either
        // produces NaN, and a NaN reaching a drawing call is silent garbage.
        let zeroWidth = TimelineGeometry(width: 0, duration: 20)
        #expect(zeroWidth.time(atX: 10).isFinite)
        #expect(zeroWidth.x(atTime: 5).isFinite)
        let zeroDuration = TimelineGeometry(width: 800, duration: 0)
        #expect(zeroDuration.time(atX: 400).isFinite)
        #expect(zeroDuration.x(atTime: 1).isFinite)
        // Added beyond the brief's probes: x/width and time/duration are 0/0
        // exactly at the origin, which is the one input the non-zero probes
        // above cannot reach (n/0 for n != 0 is +inf, and clamping saves an
        // infinity — it cannot save a NaN, since every comparison with NaN is
        // false). Without this, removing the isDegenerate guard passes this
        // test undetected.
        #expect(zeroWidth.time(atX: 0).isFinite)
        #expect(zeroDuration.x(atTime: 0).isFinite)
    }

    @Test("A cut running past the end is clamped, not drawn off the edge")
func cutPastEndIsClamped() {
    // The only cut case in this file sits entirely inside the timeline, so
    // clamping is never exercised — an implementation computing the span
    // from RAW SECONDS ((end - start) / duration * width), bypassing the
    // clamps, passes every other test here. A cut extending past `duration`
    // is the case that separates them, and a stale EDL from a longer
    // recording produces exactly that.
    let g = TimelineGeometry(width: 800, duration: 20)
    let rects = g.cutRects([TimeRange(start: 15, end: 40)])

    #expect(rects.count == 1)
    #expect(abs(rects[0].x - 600) < 0.001)
    // 15s..20s of a 20s timeline is the last quarter: 200px, NOT the 1000px
    // a raw-seconds span would give for a 25-second range.
    #expect(abs(rects[0].width - 200) < 0.001)
}

@Test("Cut rectangles cover the cut ranges and nothing else")
    func cutRectsCoverCuts() {
        let g = TimelineGeometry(width: 800, duration: 20)
        let rects = g.cutRects([TimeRange(start: 5, end: 10)])
        #expect(rects.count == 1)
        // 5s of 20 across 800px = x 200, width 200. An implementation that maps
        // start correctly but computes width from the end coordinate rather than
        // the span passes a start-only assertion.
        #expect(abs(rects[0].x - 200) < 0.001)
        #expect(abs(rects[0].width - 200) < 0.001)
    }
}
