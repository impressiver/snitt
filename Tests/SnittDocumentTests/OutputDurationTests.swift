// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// What the edit RUNS for, as opposed to what the camera recorded.
@Suite("Output duration")
struct OutputDurationTests {

    private func edl(_ cuts: [(Double, Double)]) -> EditDecisionList {
        var list = EditDecisionList.fullRange()
        list.cuts = cuts.map { Cut(range: TimeRange(start: $0.0, end: $0.1)) }
        return list
    }

    @Test("With nothing cut, the edit is the footage")
    func uncutIsUnchanged() {
        #expect(edl([]).outputDuration(sourceDuration: 58.3) == 58.3)
    }

    @Test("Each cut comes off the total")
    func cutsSubtract() {
        #expect(abs(edl([(0, 2), (10, 13)]).outputDuration(sourceDuration: 20) - 15) < 1e-9)
    }

    @Test("Overlapping cuts are counted once, not twice")
    func overlapsAreMerged() {
        // Nothing forbids two cuts overlapping — an auto-trim pass over a
        // hand-trimmed recording produces exactly that. Summing raw would
        // remove 8s from a 10s recording that really lost 5, and a longer
        // overlap drives the answer negative.
        //
        // Verified to fail by summing `cuts` without merging: reports 2.0.
        #expect(abs(edl([(1, 6), (4, 6)]).outputDuration(sourceDuration: 10) - 5) < 1e-9)
    }

    @Test("A cut wholly inside another changes nothing")
    func containmentIsNotDoubleCounted() {
        #expect(abs(edl([(2, 9), (4, 5)]).outputDuration(sourceDuration: 10) - 3) < 1e-9)
    }

    @Test("Cuts touching end to end merge into one span")
    func adjacentSpansMerge() {
        #expect(abs(edl([(1, 4), (4, 7)]).outputDuration(sourceDuration: 10) - 4) < 1e-9)
    }

    @Test("Order does not matter")
    func unsortedCutsGiveTheSameAnswer() {
        // The merge walks in order, so a list that arrives out of order would
        // silently stop merging. `edit.json` carries whatever order the editor
        // wrote, which is not guaranteed to be sorted.
        let forwards = edl([(1, 6), (4, 6)]).outputDuration(sourceDuration: 10)
        let backwards = edl([(4, 6), (1, 6)]).outputDuration(sourceDuration: 10)
        #expect(abs(forwards - backwards) < 1e-9, "\(forwards) vs \(backwards)")
    }

    @Test("A cut running past the end removes only what exists")
    func cutsAreClampedToTheFootage() {
        #expect(abs(edl([(8, 999)]).outputDuration(sourceDuration: 10) - 8) < 1e-9)
    }

    @Test("Cutting everything leaves zero, never a negative")
    func neverNegative() {
        #expect(edl([(0, 10), (0, 10)]).outputDuration(sourceDuration: 10) == 0)
    }

    @Test("An unknown footage length yields zero rather than a guess")
    func zeroSourceIsZero() {
        #expect(edl([(1, 2)]).outputDuration(sourceDuration: 0) == 0)
    }
}
