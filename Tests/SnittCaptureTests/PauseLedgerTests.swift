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

/// Markers and durations belong on the FILE's clock, not the wall's
/// (2026-09-11).
///
/// Reported from a real recording: "multiple pause/resume cause all markers
/// except the first pause/resume to show up at the end of the recording (and
/// erroneously says they're in a cut)".
///
/// The recording is in the repo's own field notes now, but the arithmetic is
/// the whole story. `Snitt-1789151395.snitt`:
///
/// - `capture.mov` is **27.742s** of footage.
/// - `meta.durationSeconds` said **49.308s**.
/// - Markers were stamped at 6.688, 18.508, 28.756, 33.224, 35.506, 40.785.
/// - Paused total: 11.819 + 4.468 + 5.279 = **21.566s**.
/// - 49.308 − 21.566 = **27.742**, exactly the footage.
///
/// So both the markers and the duration were wall-clock while the file is
/// footage. Only the first marker — before any pause — was right, which is
/// precisely what was reported. The last two exceed 27.742 altogether, so they
/// clamp to the final instant and resolve as "inside a cut".
@Suite
struct FootageClockTests {

    private func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    @Test("Paused time accumulates across every cycle, not just the first")
    func pausesAccumulate() {
        // The shape of the bug: one pause was survivable because the first
        // marker is stamped before it. Three pauses put everything after them
        // progressively further out.
        var ledger = PauseLedger()
        ledger.pause(at: time(6.688))
        ledger.resume(at: time(18.507))
        ledger.pause(at: time(28.756))
        ledger.resume(at: time(33.224))
        ledger.pause(at: time(35.506))
        ledger.resume(at: time(40.785))
        #expect(abs(ledger.totalPausedSeconds(now: time(49.308)) - 21.566) < 0.01,
                "got \(ledger.totalPausedSeconds(now: time(49.308)))")
    }

    @Test("The real recording's wall clock, corrected, is its footage length")
    func theReportedRecordingReconciles() {
        // Not a synthetic case: these are the numbers out of the bundle. The
        // correction has to land on 27.742 or the file and its metadata still
        // describe different recordings.
        var ledger = PauseLedger()
        for (pause, resume) in [(6.688, 18.507), (28.756, 33.224), (35.506, 40.785)] {
            ledger.pause(at: time(pause))
            ledger.resume(at: time(resume))
        }
        let wall = 49.308
        let footage = wall - ledger.totalPausedSeconds(now: time(wall))
        #expect(abs(footage - 27.742) < 0.02,
                "corrected duration is \(footage), the file is 27.742")
    }

    @Test("Every marker after the first lands inside the footage once corrected")
    func markersFallInsideTheFootage() {
        // The symptom, stated as the property that was violated: a marker
        // stamped during a recording is by definition at an instant the file
        // contains. Past the end it clamps, and a clamped marker sits on the
        // last frame and reads as "inside a cut" — which is what was seen.
        var ledger = PauseLedger()
        let cycles = [(6.688, 18.507), (28.756, 33.224), (35.506, 40.785)]
        let stamps = [6.688, 18.507, 28.756, 33.224, 35.506, 40.785]
        var corrected: [Double] = []
        var cycleIndex = 0
        for stamp in stamps {
            // Replay the ledger up to each stamp, as the session does.
            while cycleIndex < cycles.count, cycles[cycleIndex].0 <= stamp {
                if !ledger.isPaused { ledger.pause(at: time(cycles[cycleIndex].0)) }
                if cycles[cycleIndex].1 <= stamp {
                    ledger.resume(at: time(cycles[cycleIndex].1))
                    cycleIndex += 1
                } else { break }
            }
            corrected.append(stamp - ledger.totalPausedSeconds(now: time(stamp)))
        }
        for (stamp, footageTime) in zip(stamps, corrected) {
            #expect(footageTime <= 27.742 + 0.01,
                    "a marker stamped at \(stamp) corrects to \(footageTime), past the end of 27.742s of footage")
            #expect(footageTime >= 0)
        }
        // And uncorrected, FOUR of the six really were past the end of the
        // footage — so this fixture reproduces the report rather than merely
        // agreeing with the fix. (Four, not two: an earlier version of this
        // assertion said two and was wrong, which is the same off-by-a-pause
        // confusion the bug itself is made of.)
        #expect(stamps.filter { $0 > 27.742 }.count == 4)
    }
}

/// `meta.durationSeconds` describes the FILE (2026-09-11).
@Suite
struct FootageDurationTests {

    @Test("A paused session writes the footage length, not the wall length")
    func pausedSessionWritesFootage() {
        // The real recording: 49.308s of session, 21.566s of it paused, and a
        // capture.mov of 27.742s. The editor lays its timeline out against
        // this number, so writing the wall length gave every marker a ruler
        // longer than the recording it measures.
        let start = Date(timeIntervalSince1970: 0)
        let duration = Recorder.footageDuration(startedAt: start,
                                                stoppedAt: start.addingTimeInterval(49.308),
                                                totalPaused: 21.566)
        #expect(abs(duration - 27.742) < 0.01, "wrote \(duration)")
    }

    @Test("An unpaused session is unchanged — which is why this hid")
    func unpausedSessionIsUnchanged() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(Recorder.footageDuration(startedAt: start,
                                         stoppedAt: start.addingTimeInterval(30),
                                         totalPaused: 0) == 30)
    }

    @Test("A bundle never records a negative duration")
    func durationIsNeverNegative() {
        // Defensive, and cheap: a ledger that somehow out-counted the wall
        // would otherwise write a negative length into a file other tools read.
        let start = Date(timeIntervalSince1970: 0)
        #expect(Recorder.footageDuration(startedAt: start,
                                         stoppedAt: start.addingTimeInterval(5),
                                         totalPaused: 9) == 0)
    }
}
