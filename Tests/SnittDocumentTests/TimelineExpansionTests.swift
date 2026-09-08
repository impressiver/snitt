import Testing
import Foundation
@testable import SnittDocument

/// Expanded folds insert space into the drawn axis (M5f follow-on).
///
/// An expanded fold shows footage a cut removed. That footage has no output
/// time, so its space is INSERTED rather than mapped — everything after the
/// fold shifts right, and the playhead jumps the gap instead of appearing to
/// travel through removed footage.
///
/// The property every test here is really defending is that ONE axis does both
/// jobs: if `x(atOutput:)` inserts space and `outputTime(atX:)` does not, a
/// click after an expanded fold selects a different instant than the one under
/// the cursor. That is M4b's Critical #1.
@Suite
struct TimelineExpansionTests {
    /// 20s source, 4s cut from 5...9 → 16s output, fold at output 5.
    private func geometry(expandedSeconds: Double?) -> TimelineGeometry {
        let edl = EditDecisionList(cuts: [Cut(range: TimeRange(start: 5, end: 9))])
        let timebase = Timebase(sourceDuration: 20, edl: edl)
        let expansions = expandedSeconds.map {
            [TimelineGeometry.Expansion(output: OutputTime(5), seconds: $0)]
        } ?? []
        // 160pt wide, 16s output → 10 px/s collapsed. Expanded by 4s the axis
        // is 20s long, so fit-to-view gives 8 px/s — everything shrinks to make
        // room rather than being pushed off the right edge.
        return TimelineGeometry(width: 160, timebase: timebase, expansions: expansions)
    }

    @Test("With nothing expanded, the axis is unchanged")
    func collapsedIsUnchanged() {
        let g = geometry(expandedSeconds: nil)
        #expect(g.x(atOutput: OutputTime(5)) == 50)
        #expect(g.x(atOutput: OutputTime(6)) == 60)
    }

    @Test("An expanded fold pushes everything after it right")
    func expansionShiftsLaterContent() {
        // At 8 px/s, output 6 sits past 4 inserted seconds: (6 + 4) * 8 = 80.
        let g = geometry(expandedSeconds: 4)
        #expect(g.x(atOutput: OutputTime(4)) == 32)
        #expect(g.x(atOutput: OutputTime(6)) == 80)
    }

    @Test("The playhead jumps the band rather than crawling through it")
    func playheadSkipsTheBand() {
        // The request this exists for. Approaching the fold the playhead is at
        // 50; at the fold it is already past the band's far edge, so it never
        // appears to travel across removed footage.
        let g = geometry(expandedSeconds: 4)
        #expect(g.x(atOutput: OutputTime(4.99)) < 40.0)
        #expect(g.x(atOutput: OutputTime(5)) == 72, "the playhead entered the band")
    }

    @Test("A pixel inside the band resolves to the cut, not to later content")
    func clicksInsideTheBandLandOnTheCut() {
        // The band spans 40...72. Every pixel in it is removed footage, so it
        // answers with the fold — the same answer a collapsed fold gives.
        let g = geometry(expandedSeconds: 4)
        #expect(g.outputTime(atX: 45).seconds == 5)
        #expect(g.outputTime(atX: 71).seconds == 5)
    }

    @Test("The two mappings are exact inverses on both sides of the band")
    func mappingsAreInverses() {
        // THE assertion. A drawing that inserts space while gestures do not is
        // how the two axes come to disagree.
        let g = geometry(expandedSeconds: 4)
        for output in [0.0, 2.5, 4.9, 5.0, 8.0, 12.0, 15.9] {
            let x = g.x(atOutput: OutputTime(output))
            let back = g.outputTime(atX: x).seconds
            #expect(abs(back - output) < 0.001,
                    "output \(output) → x \(x) → \(back)")
        }
    }

    @Test("Expansions survive a zoom")
    func expansionsSurviveZoom() {
        // Zoom rebuilds the geometry; dropping expansions there would make the
        // axes disagree only after someone zoomed, which is the worst kind of
        // bug to find.
        let zoomed = geometry(expandedSeconds: 4).zoomed(by: 2, anchoredAt: OutputTime(0))
        #expect(zoomed.expandedSeconds == 4)
        let x = zoomed.x(atOutput: OutputTime(6))
        #expect(abs(zoomed.outputTime(atX: x).seconds - 6) < 0.001)
    }

    @Test("Two expanded folds accumulate")
    func multipleExpansionsAccumulate() {
        let edl = EditDecisionList(cuts: [Cut(range: TimeRange(start: 5, end: 9)),
                                          Cut(range: TimeRange(start: 12, end: 14))])
        let timebase = Timebase(sourceDuration: 20, edl: edl)
        // Output is 20 - 6 = 14s; folds at output 5 and 8.
        // 14s output + 6s inserted = 20s in 140pt → 7 px/s.
        let g = TimelineGeometry(width: 140, timebase: timebase, expansions: [
            TimelineGeometry.Expansion(output: OutputTime(5), seconds: 4),
            TimelineGeometry.Expansion(output: OutputTime(8), seconds: 2),
        ])
        // Output 10 sits past both bands: (10 + 6) * 7 = 112.
        #expect(g.x(atOutput: OutputTime(10)) == 112)
        #expect(abs(g.outputTime(atX: 112).seconds - 10) < 0.001)
    }
}
