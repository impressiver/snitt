// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// Stepping between marks (D84).
@Suite
struct MarkerNavigationTests {
    private func mark(_ label: String, _ time: Double, insideCut: Bool = false) -> JumpPoint {
        JumpPoint(id: UUID(), timeSeconds: time, label: label,
                  transcript: nil, isInsideCut: insideCut)
    }
    private var marks: [JumpPoint] {
        [mark("open", 0), mark("fix", 8), mark("re-run", 19)]
    }

    @Test("Next steps forward one mark")
    func nextAdvances() {
        #expect(MarkerNavigation.next(after: 2, in: marks)?.label == "fix")
        #expect(MarkerNavigation.next(after: 10, in: marks)?.label == "re-run")
    }

    @Test("Next at the last mark has nowhere to go")
    func nextStopsAtTheEnd() {
        #expect(MarkerNavigation.next(after: 25, in: marks) == nil)
    }

    @Test("Next from exactly ON a mark advances rather than re-selecting it")
    func nextFromExactlyOnAMark() {
        // Landing on a mark and pressing Next must move. Without the epsilon,
        // floating-point noise from a seek puts the playhead a hair before the
        // mark it just jumped to, and Next selects that same mark again — a
        // key that visibly does nothing.
        #expect(MarkerNavigation.next(after: 8, in: marks)?.label == "re-run")
    }

    @Test("Previous a long way past a mark returns to THAT mark")
    func previousRestartsTheCurrentMark() {
        // The music-player idiom people already have in their fingers:
        // Previous partway into a track restarts it. Five seconds past "fix",
        // Previous means "fix" — the mark you were actually listening to.
        #expect(MarkerNavigation.previous(before: 13, in: marks)?.label == "fix")
    }

    @Test("Previous immediately after a mark steps back past it")
    func previousTwiceGoesBackOne() {
        // The other half of the idiom: pressing it again, still within the
        // settle window, goes back one. An implementation without the settle
        // window returns "fix" here and the second press does nothing.
        #expect(MarkerNavigation.previous(before: 8.2, in: marks)?.label == "open")
    }

    @Test("Previous before the first mark has nowhere to go")
    func previousStopsAtTheStart() {
        #expect(MarkerNavigation.previous(before: 0.2, in: marks) == nil)
    }

    @Test("Marks are stepped in time order regardless of how they arrive")
    func orderIsByTime() {
        // Events are appended in the order they were logged, and a marker
        // dragged earlier on the timeline does not reorder that array.
        let shuffled = [mark("re-run", 19), mark("open", 0), mark("fix", 8)]
        #expect(MarkerNavigation.next(after: 2, in: shuffled)?.label == "fix")
        #expect(MarkerNavigation.previous(before: 13, in: shuffled)?.label == "fix")
    }

    @Test("Two marks collapsed onto one fold are stepped through once")
    func duplicateTimesAreOneStop() {
        // Both markers inside a single cut map to that fold's one output
        // instant, and Next must not stop twice there — a key that leaves the
        // playhead where it was looks broken. The work is done by `epsilon`,
        // not by deduplication: from 5.0, `next` looks for `> 5.01` and skips
        // every mark at 5.0. An explicit dedupe was tried, found redundant by
        // a surviving mutant, and removed.
        let folded = [mark("a", 0), mark("b", 5, insideCut: true),
                      mark("c", 5, insideCut: true), mark("d", 12)]
        #expect(MarkerNavigation.next(after: 0.5, in: folded)?.timeSeconds == 5)
        #expect(MarkerNavigation.next(after: 5, in: folded)?.label == "d",
                "Next stopped twice on one fold")
    }

    @Test("The current mark is the most recent one at or before the playhead")
    func currentNamesTheMarkYouAreIn() {
        // What the transport readout shows — the agent-authored label, on
        // screen, without opening the chapters list.
        #expect(MarkerNavigation.current(at: 12, in: marks)?.label == "fix")
        #expect(MarkerNavigation.current(at: 8, in: marks)?.label == "fix")
        #expect(MarkerNavigation.current(at: 0, in: marks)?.label == "open")
    }

    @Test("Before the first mark there is no current mark")
    func noCurrentMarkBeforeTheFirst() {
        let later = [mark("fix", 8)]
        #expect(MarkerNavigation.current(at: 3, in: later) == nil)
    }

    @Test("An unmarked recording navigates nowhere rather than crashing")
    func emptyIsSafe() {
        #expect(MarkerNavigation.next(after: 5, in: []) == nil)
        #expect(MarkerNavigation.previous(before: 5, in: []) == nil)
        #expect(MarkerNavigation.current(at: 5, in: []) == nil)
    }
}
