// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import Testing
@testable import SnittApp

// `EditorWindowTestGate` must turn a stuck holder into a FAILURE, never a hang.
//
// The sibling of `SparkleTestGateTests`, and the more important of the two:
// this gate has 52 call sites across 10 files against that one's five, so an
// unbounded wait here takes far more of the suite down with it.
//
// Both gates carried the same defect — `acquire()` parked on a
// `CheckedContinuation` with no ceiling — and it is worth naming the shape
// rather than the instance: any wait that cannot expire will, eventually,
// not expire. The failure it produces is the worst kind, because a hang is
// indistinguishable from ordinary slow progress, costs the whole run rather
// than one test, and names nobody.
@Suite(.serialized)
@MainActor
struct EditorWindowTestGateTests {

    @Test("A holder that never finishes fails its waiters instead of hanging them")
    func stuckHolderFailsWaitersRatherThanHangingThem() async throws {
        // ITS OWN GATE, and a holder that holds until this test SAYS SO.
        //
        // Two independent bugs lived in these five lines, and both were
        // resolved by removing an assumption rather than by waiting longer.
        //
        // 1. It used the SHARED gate. The timeout message names whoever holds
        //    the gate AT THE MOMENT IT FIRES, so a real EditorWindowTestGate test that took
        //    the gate in between was named instead — truthfully. That is the
        //    intermittent failure this suite carried from 2026-09-07 to
        //    2026-09-11. No amount of polling fixes a shared resource.
        //
        // 2. The holder held for a fixed 1.5s. That is a bet that this test
        //    can get back onto the main actor within 1.5s, and in a full-suite
        //    run — ~138 `@MainActor` suites competing — it loses: the holder's
        //    sleep expires before the waiter below can even attempt to
        //    acquire, the waiter then SUCCEEDS, and the test fails claiming
        //    the timeout did not work. Measured, not predicted.
        //
        // So the holder now blocks on a latch this test opens. There is no
        // duration to lose a race against: when the waiter runs, the gate is
        // held, whatever the scheduler did in between.
        let gate = EditorWindowTestGate()
        let latch = Latch()
        let holder = Task { @MainActor in
            try await gate.run("a deliberately stuck holder") {
                while !latch.open { try await Task.sleep(nanoseconds: 10_000_000) }
            }
        }
        defer { latch.open = true; holder.cancel() }

        while gate.currentHolder != "a deliberately stuck holder" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let started = Date()
        do {
            try await gate.run("the waiter", timeout: 0.3) { }
            Issue.record("the waiter acquired a gate that was held — it should have timed out")
        } catch let timeout as EditorWindowTestGate.Timeout {
            // Naming the HOLDER is the point. When this fires for real, every
            // queued windowed test fails at once and the only useful question
            // is which one never let go.
            #expect(timeout.description.contains("a deliberately stuck holder"),
                    "the timeout does not name the holder: \(timeout.description)")
        }

        // Bounded in fact, not just in intent — but the ceiling is LOOSE, and
        // the reason is the lesson of this file. `acquire` notices its own
        // deadline by polling on the main actor, and in a full-suite run ~138
        // suites of `@MainActor` tests compete for it, so the hop after each
        // sleep queues behind them: MEASURED at 3.2s of wall clock to observe
        // a 0.3s deadline (6.8s for the Sparkle gate's twin of this test). A
        // tight ceiling asserts main-actor scheduling latency, not the gate.
        //
        // It passed at 3.0s only while this test shared the real gate, and
        // that was luck standing in for a guarantee: holding the shared gate
        // PARKED every windowed test, freeing the main actor this measurement
        // depends on. A private gate removes that accidental back-pressure.
        //
        // The timeout itself is pinned by the branch above, load-independently:
        // the holder sleeps 1.5s, so a waiter whose timeout was ignored
        // ACQUIRES and trips `Issue.record`. This line only separates "gave
        // up" from "hung forever".
        let waited = Date().timeIntervalSince(started)
        #expect(waited < 60.0, "the waiter hung rather than giving up: \(waited)s")

        latch.open = true
        _ = await holder.result
    }

    @Test("The gate is released after a body throws, not left locked forever")
    func aThrowingBodyStillReleasesTheGate() async throws {
        struct Boom: Error {}
        // A private gate, as above: asserting the SHARED gate is unheld is
        // asserting that no windowed test is running — not this test's
        // business, and not true under parallelism.
        let gate = EditorWindowTestGate()
        do {
            try await gate.run("a throwing body") { throw Boom() }
            Issue.record("the body's error was swallowed")
        } catch is Boom {
            // expected
        }
        // Dropping `defer { release() }` would strand the gate: every windowed
        // test after the first failure would then fail too, which is how one
        // defect becomes fifty.
        #expect(gate.currentHolder == nil, "the gate stayed locked after a throw")
        try await gate.run("a later test", timeout: 1.0) { }
    }

    @Test("An ordinary holder is not penalised for being slow")
    func aSlowButFinishingHolderIsFine() async throws {
        // The bound catches a holder that will NEVER finish, not a slow one.
        // Window tests queue behind this gate constantly and their reported
        // durations are dominated by that queueing, so a gate that punished
        // slowness would fail honest tests continuously.
        //
        // 30s, raised from 5. Under a full-suite run this test queued behind
        // `openingAndClosingDoesNotStamp()` — which opens a real editor window
        // — and gave up at 5s, failing the gate intermittently while passing
        // every time the suite was run in isolation. A test asserting "a slow
        // holder is not penalised" that itself fails because a holder was slow
        // is measuring the machine, not the gate. The number that matters is
        // still bounded: a holder that never finishes fails here in 30s rather
        // than hanging the run forever, which is the whole reason this bound
        // exists.
        let gate = EditorWindowTestGate()
        try await gate.run("a slow but honest holder", timeout: 30.0) {
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        #expect(gate.currentHolder == nil)
    }
}
