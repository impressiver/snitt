import Testing
@testable import SnittDocument

@Suite("TimelineGeometry")
struct TimelineGeometryTests {
    @Test("A cut shortens the timeline")
    func cutShortensTimeline() {
        let edl = EditDecisionList(cuts: [Cut(range: TimeRange(start: 2, end: 4))])
        let base = Timebase(sourceDuration: 10, edl: edl)
        let geometry = TimelineGeometry(width: 800, timebase: base)

        // The whole point: 8s of output across the full width, not 10s.
        #expect(geometry.duration == 8)
        // The end of the source maps to the end of the view.
        #expect(abs(geometry.x(atOutput: OutputTime(8)) - 800) < 0.001)
        // A source time inside the cut has no x — it is not in the export.
        #expect(geometry.x(atSource: SourceTime(3)) == nil)
    }

    @Test("A source time past a cut maps to its SHIFTED output position")
    func sourceTimeAfterACutShiftsByTheCutLength() {
        // 10s source, [2,4) cut: 8s of output. Source 6 sits 2s into the
        // second kept range [4,10) — output 4, not the raw 6 an
        // implementation that forgot to consult the cut at all would give,
        // and not some other value that only gets the NIL-inside-a-cut case
        // right without getting the SHIFT right for what survives it.
        let edl = EditDecisionList(cuts: [Cut(range: TimeRange(start: 2, end: 4))])
        let geometry = TimelineGeometry(width: 800, timebase: Timebase(sourceDuration: 10, edl: edl))
        let x = geometry.x(atSource: SourceTime(6))
        #expect(x != nil)
        if let x {
            // Output 4 of 8 total, across 800px, is the midpoint: 400.
            #expect(abs(x - 400) < 0.001)
        }
    }

    @Test("Output time and x round-trip")
    func outputTimeAndXRoundTrip() {
        let g = TimelineGeometry(width: 800, timebase: Timebase(sourceDuration: 20, edl: EditDecisionList()))
        for t in [0.0, 3.7, 10.0, 19.99, 20.0] {
            let x = g.x(atOutput: OutputTime(t))
            #expect(abs(g.outputTime(atX: x).seconds - t) < 0.001)
        }
    }

    @Test("The ends map to the ends")
    func endsMapToEnds() {
        let g = TimelineGeometry(width: 800, timebase: Timebase(sourceDuration: 20, edl: EditDecisionList()))
        #expect(g.x(atOutput: OutputTime(0)) == 0)
        #expect(g.x(atOutput: OutputTime(20)) == 800)
        #expect(g.outputTime(atX: 0).seconds == 0)
        #expect(abs(g.outputTime(atX: 800).seconds - 20) < 0.001)
    }

    @Test("Positions outside the view clamp instead of extrapolating")
    func outOfRangeClamps() {
        let g = TimelineGeometry(width: 800, timebase: Timebase(sourceDuration: 20, edl: EditDecisionList()))
        // A drag can leave the view; extrapolating gives a negative time or one
        // past the end, and an EDL cut built from it is nonsense.
        #expect(g.outputTime(atX: -50).seconds == 0)
        #expect(abs(g.outputTime(atX: 900).seconds - 20) < 0.001)
        #expect(g.x(atOutput: OutputTime(-5)) == 0)
        #expect(g.x(atOutput: OutputTime(25)) == 800)
    }

    @Test("A zero-width or zero-duration timeline yields no NaN")
    func degenerateGeometryIsFinite() {
        // A view gets laid out at zero width before its first real layout pass,
        // and a bundle can be a fraction of a second long. Division by either
        // produces NaN, and a NaN reaching a drawing call is silent garbage.
        let zeroWidth = TimelineGeometry(width: 0, timebase: Timebase(sourceDuration: 20, edl: EditDecisionList()))
        #expect(zeroWidth.outputTime(atX: 10).seconds.isFinite)
        #expect(zeroWidth.x(atOutput: OutputTime(5)).isFinite)
        // Everything cut away is ALSO zero output duration, not just a
        // zero-length recording — `Timebase.outputDuration` is what feeds
        // `duration` now, so this is the more realistic degenerate case.
        let zeroDuration = TimelineGeometry(
            width: 800,
            timebase: Timebase(sourceDuration: 20, edl: EditDecisionList(cuts: [Cut(range: TimeRange(start: 0, end: 20))])))
        #expect(zeroDuration.duration == 0)
        #expect(zeroDuration.outputTime(atX: 400).seconds.isFinite)
        #expect(zeroDuration.x(atOutput: OutputTime(1)).isFinite)
        // Added beyond the brief's probes: x/width and time/duration are 0/0
        // exactly at the origin, which is the one input the non-zero probes
        // above cannot reach (n/0 for n != 0 is +inf, and clamping saves an
        // infinity — it cannot save a NaN, since every comparison with NaN is
        // false). Without this, removing the isDegenerate guard passes this
        // test undetected.
        #expect(zeroWidth.outputTime(atX: 0).seconds.isFinite)
        #expect(zeroDuration.x(atOutput: OutputTime(0)).isFinite)
    }

    // MARK: - x(atFold:) (M5f Task 5: a cut draws as a fold, not a gap)

    @Test("A fold draws at the pixel where the cut's two edges meet, not at x(atSource:)'s nil")
    func foldDrawsAtTheMeetingPoint() {
        // 10s source, cut [3,5): 8s of output, cut folds to output 3 (see
        // `TimebaseTests.interiorCutFoldsWhereKeptContentBeforeItEnds`).
        // Output 3 of 8 total, across 800px: 300.
        let cut = Cut(range: TimeRange(start: 3, end: 5))
        let geometry = TimelineGeometry(width: 800, timebase: Timebase(sourceDuration: 10, edl: EditDecisionList(cuts: [cut])))
        // `x(atSource:)` on the cut's OWN start (3, the end of the kept
        // range before it) is `nil` — that instant has no output position —
        // which is exactly why a fold needs its own dedicated mapping
        // rather than reusing that one. (The cut's END edge, 5, is a
        // different case: per `TimeRangeMapping`'s boundary rule it's
        // exactly the START of the NEXT kept range, so `x(atSource:)` DOES
        // answer there — it maps to this same output instant, 3, since
        // that's where the resumed kept content begins. Only the cut's
        // start is genuinely unanswerable by `x(atSource:)`.)
        #expect(geometry.x(atSource: SourceTime(3)) == nil)
        #expect(abs(geometry.x(atFold: cut) - 300) < 0.001)
    }

    @Test("A fold's x is finite even when everything is cut")
    func foldXIsFiniteWhenDegenerate() {
        let cut = Cut(range: TimeRange(start: 0, end: 10))
        let geometry = TimelineGeometry(
            width: 800, timebase: Timebase(sourceDuration: 10, edl: EditDecisionList(cuts: [cut])))
        #expect(geometry.duration == 0)
        #expect(geometry.x(atFold: cut).isFinite)
    }
}
