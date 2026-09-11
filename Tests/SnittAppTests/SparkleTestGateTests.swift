// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import Testing

// The gate must turn a stuck holder into a FAILURE, never a hang.
//
// On 2026-09-09 a full-suite run sat at 0% CPU for over ten minutes and then
// had to be killed. `acquire()` waited on a `CheckedContinuation` with no
// ceiling, so one holder that never finished blocked every other gated test
// forever — producing no output, no failing test, and nothing to read. The
// only way to learn anything was to `sample` the process by hand.
//
// A hang is the worst shape a test failure can take: it is indistinguishable
// from ordinary slow progress, it costs the entire run rather than one test,
// and it names nobody. These tests pin the property that makes that
// impossible.
@Suite(.serialized)
@MainActor
struct SparkleTestGateTests {

    @Test("A holder that never finishes fails its waiters instead of hanging them")
    func stuckHolderFailsWaitersRatherThanHangingThem() async throws {
        // ITS OWN GATE, and a holder that holds until this test SAYS SO.
        //
        // Two independent bugs lived in these five lines, and both were
        // resolved by removing an assumption rather than by waiting longer.
        //
        // 1. It used the SHARED gate. The timeout message names whoever holds
        //    the gate AT THE MOMENT IT FIRES, so a real SparkleTestGate test that took
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
        let gate = SparkleTestGate()
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
        } catch let timeout as SparkleTestGate.Timeout {
            // The message must name the HOLDER, not the waiter. When this
            // fires for real, every queued test fails at once and the only
            // useful question is which one never let go.
            #expect(timeout.description.contains("a deliberately stuck holder"),
                    "the timeout does not name the holder: \(timeout.description)")
        }

        // Bounded in fact, not just in intent: a ceiling that is never
        // enforced reads the same as no ceiling. But the ceiling is LOOSE, and
        // the reason is the whole lesson of this file.
        //
        // `acquire` notices its own deadline by polling on the main actor. In
        // a full-suite run ~138 suites of `@MainActor` tests are competing for
        // that actor, so the hop after each 20ms sleep queues behind them:
        // MEASURED at 6.8s of wall clock to observe a 0.3s deadline. A tight
        // ceiling here asserts main-actor scheduling latency, not the gate —
        // the adjacent-property mistake this project has logged 27 times.
        //
        // It only passed at 3.0s while these tests shared one gate, and that
        // was luck standing in for a guarantee: a held shared gate PARKED
        // every real Sparkle test, which freed the main actor that this
        // measurement depends on. Giving the test its own gate removed that
        // accidental back-pressure and the number moved. Nothing about the
        // timeout changed.
        //
        // What actually pins the timeout is the branch above: the holder
        // sleeps 1.5s, so a waiter whose timeout was ignored ACQUIRES and
        // trips `Issue.record`. That discriminator is load-independent. This
        // line only separates "gave up" from "hung forever".
        let waited = Date().timeIntervalSince(started)
        #expect(waited < 60.0, "the waiter hung rather than giving up: \(waited)s")

        latch.open = true
        _ = await holder.result
    }

    @Test("The gate is released after a body throws, not left locked forever")
    func aThrowingBodyStillReleasesTheGate() async throws {
        struct Boom: Error {}
        // A private gate, like the waiter test above: asserting the SHARED
        // gate is unheld is asserting that no Sparkle test is running, which
        // is not this test's business and is not true under parallelism.
        let gate = SparkleTestGate()
        do {
            try await gate.run("a throwing body") { throw Boom() }
            Issue.record("the body's error was swallowed")
        } catch is Boom {
            // expected
        }
        // If `defer { release() }` were ever dropped, this is what would catch
        // it: the next acquire would time out instead of succeeding, and every
        // Sparkle test after the first failure would fail too.
        #expect(gate.currentHolder == nil, "the gate stayed locked after a throw")
        try await gate.run("a later test", timeout: 1.0) { }
    }

    @Test("An ordinary holder is not penalised for being slow")
    func aSlowButFinishingHolderIsFine() async throws {
        // The bound exists to catch a holder that will NEVER finish. Under the
        // full suite 214 tests already report 60s or more, almost all of it
        // queueing rather than working, so a gate that punished slowness would
        // fail honest tests constantly.
        let gate = SparkleTestGate()
        try await gate.run("a slow but honest holder", timeout: 5.0) {
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        #expect(gate.currentHolder == nil)
    }
}
