// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import CoreMedia
@testable import SnittCapture

/// The arithmetic behind pause/resume (M5e, D53).
///
/// This is the part that can be wrong invisibly. A shift that is off by one
/// pause produces a file that plays perfectly and whose every marker, event and
/// cut lands at the wrong instant — §4.12's markers and the whole EDL are on
/// this clock. So the assertions here are about the SECOND pause as much as the
/// first: an implementation that tracks only the current pause and forgets
/// earlier ones passes every single-pause test.
@Suite
struct PauseLedgerTests {
    private func t(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    @Test("With no pause, timestamps pass through untouched")
    func noPauseIsIdentity() {
        let ledger = PauseLedger()
        #expect(ledger.adjusted(t(5)) == t(5))
        #expect(!ledger.isPaused)
    }

    @Test("A pause shifts later timestamps back by its length")
    func onePauseShifts() {
        var ledger = PauseLedger()
        ledger.pause(at: t(10))
        ledger.resume(at: t(13))
        // 3 seconds paused: a source instant at 20s is written at 17s, so the
        // file is continuous rather than carrying a 3s frozen gap.
        #expect(ledger.adjusted(t(20)) == t(17))
    }

    @Test("Pauses ACCUMULATE — the second does not replace the first")
    func pausesAccumulate() {
        // The assertion that matters. An implementation holding only the
        // current pause span passes every test above and puts every marker
        // after the second resume three seconds late.
        var ledger = PauseLedger()
        ledger.pause(at: t(10)); ledger.resume(at: t(13))   // 3s
        ledger.pause(at: t(20)); ledger.resume(at: t(24))   // 4s
        #expect(ledger.totalPaused == t(7))
        #expect(ledger.adjusted(t(30)) == t(23))
    }

    @Test("Pausing twice keeps the ORIGINAL start")
    func doublePauseKeepsTheFirstStart() {
        // Taking the later timestamp silently shortens the pause and shifts
        // everything after it forward by the difference. A double pause is
        // ordinary: an agent retrying a call, or a person clicking twice.
        var ledger = PauseLedger()
        ledger.pause(at: t(10))
        ledger.pause(at: t(12))
        ledger.resume(at: t(15))
        #expect(ledger.totalPaused == t(5), "the second pause() moved the start")
    }

    @Test("Resuming without pausing changes nothing")
    func strayResumeIsInert() {
        var ledger = PauseLedger()
        ledger.resume(at: t(10))
        #expect(ledger.totalPaused == .zero)
        #expect(ledger.adjusted(t(20)) == t(20))
    }

    @Test("A resume BEFORE the pause cannot run the clock backwards")
    func backwardsResumeIsClamped() {
        // Timestamps come from a live clock across a concurrent queue; an
        // out-of-order pair is not impossible. A negative span would shrink
        // totalPaused and shift later buffers the wrong way.
        var ledger = PauseLedger()
        ledger.pause(at: t(10))
        ledger.resume(at: t(8))
        #expect(ledger.totalPaused == .zero)
        #expect(!ledger.isPaused, "the pause must still end")
    }

    @Test("maxDuration counts paused time; recorded elapsed does not")
    func limitCountsPausedTimeButFootageDoesNot() {
        // D53 left this open and it is settled here: maxDuration is the
        // backstop for an unattended agent run, and D53 itself names "an agent
        // forgets to resume" as the case where a human is the only fallback.
        // If paused time did not count, a forgotten pause would run forever —
        // exactly the runaway the limit exists to prevent.
        var ledger = PauseLedger()
        ledger.pause(at: t(10))
        ledger.resume(at: t(40))    // 30s paused
        #expect(ledger.elapsedAgainstLimit(since: t(0), now: t(60)) == t(60))
        #expect(ledger.recordedElapsed(since: t(0), now: t(60)) == t(30))
    }

    @Test("An OPEN pause still counts against the limit as it grows")
    func openPauseCountsWhileItIsOpen() {
        // The forgotten-resume case: nothing has called resume(), so a ledger
        // that only counted CLOSED pauses would report the session as young
        // forever and never trip the limit.
        var ledger = PauseLedger()
        ledger.pause(at: t(10))
        #expect(ledger.elapsedAgainstLimit(since: t(0), now: t(600)) == t(600))
        #expect(ledger.recordedElapsed(since: t(0), now: t(600)) == t(10))
    }
}
