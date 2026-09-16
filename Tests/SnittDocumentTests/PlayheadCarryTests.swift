// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// Where the playhead lands after an edit rebuilds the composition.
///
/// `AVPlayer.replaceCurrentItem` starts the new item at zero, so every edit
/// sent the playhead home. The visible jump was the smaller half: the next
/// over-dub reads the playhead to decide where it was spoken, read 0, and
/// claimed to cover the opening seconds of the recording — so the words it was
/// meant to replace survived, being nowhere near what it said it covered.
///
/// Reported as "re-transcribe is including words from the original audio that
/// got overdubbed", and confirmed in a real document: four takes, every one of
/// them anchored at source 0.
struct PlayheadCarryTests {

    private let whole = [TimeRange(start: 0, end: 60)]

    @Test("An edit that changes nothing leaves the playhead exactly where it was")
    func unchangedTimelineKeepsThePosition() {
        // The case the over-dub bug lived in: recording a take appends to the
        // EDL and rebuilds, but removes no footage. The playhead must not move
        // at all, or the NEXT take is anchored somewhere nobody was.
        #expect(PlayheadCarry.carried(outputTime: 12.5, before: whole, after: whole) == 12.5)
    }

    @Test("A cut ABOVE the playhead pulls it earlier by the cut's length")
    func cutAboveMovesItEarlier() {
        // Output time means different footage after an edit. Holding the
        // number would hold the wrong moment precisely when the edit mattered.
        let after = [TimeRange(start: 0, end: 5), TimeRange(start: 10, end: 60)]
        // Output 20 was source 20 before; after removing 5-10 it is output 15.
        #expect(PlayheadCarry.carried(outputTime: 20, before: whole, after: after) == 15)
    }

    @Test("A cut BELOW the playhead does not move it")
    func cutBelowLeavesItAlone() {
        let after = [TimeRange(start: 0, end: 30), TimeRange(start: 40, end: 60)]
        #expect(PlayheadCarry.carried(outputTime: 10, before: whole, after: after) == 10)
    }

    @Test("Undoing a cut puts the playhead back where the footage went")
    func restoringFootageCarriesBack() {
        // The reverse direction, which a one-way mapping would get wrong: the
        // playhead follows the FRAMES rather than the number.
        let trimmed = [TimeRange(start: 0, end: 5), TimeRange(start: 10, end: 60)]
        #expect(PlayheadCarry.carried(outputTime: 15, before: trimmed, after: whole) == 20)
    }

    @Test("A playhead standing on footage the edit removed has no answer")
    func removedFootageIsNil() {
        // Refused rather than invented: the honest answers — the cut's near
        // edge, the start — are a presentation choice, not arithmetic.
        let after = [TimeRange(start: 0, end: 5), TimeRange(start: 10, end: 60)]
        #expect(PlayheadCarry.carried(outputTime: 7, before: whole, after: after) == nil)
    }

    @Test("The fallback lands near the lost moment rather than at the start")
    func fallbackClampsRatherThanResets() {
        // A playhead that jumps to the beginning after an edit loses the place
        // you were working in, which is the whole complaint.
        let after = [TimeRange(start: 0, end: 5), TimeRange(start: 10, end: 60)]
        let landing = PlayheadCarry.carriedOrNearest(outputTime: 7, before: whole,
                                                     after: after, newDuration: 55)
        #expect(landing == 7, "it reset to \(landing)")
    }

    @Test("It never lands past the end of what survives")
    func clampedToTheNewDuration() {
        // Cutting the tail while parked in it. Seeking past the end leaves the
        // player at a position it cannot render.
        let after = [TimeRange(start: 0, end: 10)]
        let landing = PlayheadCarry.carriedOrNearest(outputTime: 50, before: whole,
                                                     after: after, newDuration: 10)
        #expect(landing == 10)
    }

    @Test("It never lands before the start")
    func clampedAtZero() {
        let landing = PlayheadCarry.carriedOrNearest(outputTime: -5, before: whole,
                                                     after: whole, newDuration: 60)
        #expect(landing == 0)
    }
}
