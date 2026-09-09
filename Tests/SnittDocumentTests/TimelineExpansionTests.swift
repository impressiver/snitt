// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

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

/// Where an expanded fold's band is DRAWN, as opposed to where its fold sits.
///
/// These are two different questions and conflating them produced a real
/// defect: `x(atFold:)` answers "the instant the cut collapsed to", which after
/// insertion is the band's TRAILING edge — the first surviving frame. Drawing
/// the band from there put it one full width too far right, over the content
/// that follows, and left the reserved space blank.
@Suite
struct ExpansionSpanTests {
    private func fixture() -> (TimelineGeometry, Cut, Timebase) {
        // 20s source, 4s cut at 5...9 → 16s output, fold at output 5.
        let cut = Cut(range: TimeRange(start: 5, end: 9))
        let timebase = Timebase(sourceDuration: 20, edl: EditDecisionList(cuts: [cut]))
        // 200pt, 16s output + 4s inserted = 20s → 10 px/s.
        let g = TimelineGeometry(width: 200, timebase: timebase, expansions: [
            .init(output: timebase.foldPosition(for: cut), seconds: 4)
        ])
        return (g, cut, timebase)
    }

    @Test("The band occupies exactly the space the axis inserted")
    func bandFillsTheInsertedSpace() throws {
        let (g, cut, timebase) = fixture()
        let span = try #require(g.expansionSpan(atOutput: timebase.foldPosition(for: cut)))
        // Content before the fold ends at 50; content after it resumes at 90.
        // The band is exactly that gap.
        #expect(span.x == 50, "band starts at \(span.x), gap starts at 50")
        #expect(span.width == 40)
        #expect(span.x + span.width == g.x(atOutput: OutputTime(5)),
                "the band does not meet the first surviving instant")
    }

    @Test("The band is NOT at x(atFold:) — that is its far edge")
    func bandIsNotAtTheFoldPosition() throws {
        // The defect, pinned. x(atFold:) is 90; drawing there put the band at
        // 90...130, over the content drawn for output 5...9.
        let (g, cut, timebase) = fixture()
        let span = try #require(g.expansionSpan(atOutput: timebase.foldPosition(for: cut)))
        #expect(g.x(atFold: cut) == span.x + span.width)
        #expect(span.x != g.x(atFold: cut))
    }

    @Test("Nothing is drawn in the band's span by the output mapping")
    func nothingElseOccupiesTheBand() {
        // Proof the gap is genuinely reserved: sweep every output instant and
        // confirm none is drawn strictly inside the band.
        let (g, _, _) = fixture()
        for step in stride(from: 0.0, through: 16.0, by: 0.05) {
            let x = g.x(atOutput: OutputTime(step))
            #expect(!(x > 50.001 && x < 89.999),
                    "output \(step) draws at \(x), inside the band")
        }
    }

    @Test("A collapsed fold has no span")
    func collapsedFoldHasNoSpan() {
        let cut = Cut(range: TimeRange(start: 5, end: 9))
        let timebase = Timebase(sourceDuration: 20, edl: EditDecisionList(cuts: [cut]))
        let g = TimelineGeometry(width: 200, timebase: timebase)
        #expect(g.expansionSpan(atOutput: timebase.foldPosition(for: cut)) == nil)
    }

    @Test("With two expanded folds, the second's band sits past the first's")
    func secondBandAccountsForTheFirst() throws {
        let first = Cut(range: TimeRange(start: 5, end: 9))
        let second = Cut(range: TimeRange(start: 12, end: 14))
        let timebase = Timebase(sourceDuration: 20,
                                edl: EditDecisionList(cuts: [first, second]))
        // Output 14s + 6s inserted = 20s in 200pt → 10 px/s.
        let g = TimelineGeometry(width: 200, timebase: timebase, expansions: [
            .init(output: timebase.foldPosition(for: first), seconds: 4),
            .init(output: timebase.foldPosition(for: second), seconds: 2),
        ])
        let a = try #require(g.expansionSpan(atOutput: timebase.foldPosition(for: first)))
        let b = try #require(g.expansionSpan(atOutput: timebase.foldPosition(for: second)))
        #expect(a.x == 50)
        // Second fold is at output 8; 4s already inserted before it → x 120.
        #expect(b.x == 120, "second band at \(b.x) — it ignored the first's insertion")
        #expect(b.x >= a.x + a.width)
    }
}
