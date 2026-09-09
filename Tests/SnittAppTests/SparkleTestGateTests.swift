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
        // Acquire from a separate task and keep the gate. This task may itself
        // have to queue behind a real Sparkle test — that is fine and is why
        // the wait below polls `currentHolder` rather than assuming immediate
        // acquisition. Without that wait this test would race the real
        // Sparkle-driving tests and blame whichever one happened to hold it.
        let holder = Task { @MainActor in
            try await SparkleTestGate.run("a deliberately stuck holder") {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        defer { holder.cancel() }

        while SparkleTestGate.currentHolder != "a deliberately stuck holder" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let started = Date()
        do {
            try await SparkleTestGate.run("the waiter", timeout: 0.3) { }
            Issue.record("the waiter acquired a gate that was held — it should have timed out")
        } catch let timeout as SparkleTestGate.Timeout {
            // The message must name the HOLDER, not the waiter. When this
            // fires for real, every queued test fails at once and the only
            // useful question is which one never let go.
            #expect(timeout.description.contains("a deliberately stuck holder"),
                    "the timeout does not name the holder: \(timeout.description)")
        }

        // Bounded in fact, not just in intent: a ceiling that is never enforced
        // reads the same as no ceiling.
        let waited = Date().timeIntervalSince(started)
        #expect(waited < 3.0, "the waiter took \(waited)s to give up on a 0.3s timeout")

        _ = await holder.result
    }

    @Test("The gate is released after a body throws, not left locked forever")
    func aThrowingBodyStillReleasesTheGate() async throws {
        struct Boom: Error {}
        do {
            try await SparkleTestGate.run("a throwing body") { throw Boom() }
            Issue.record("the body's error was swallowed")
        } catch is Boom {
            // expected
        }
        // If `defer { release() }` were ever dropped, this is what would catch
        // it: the next acquire would time out instead of succeeding, and every
        // Sparkle test after the first failure would fail too.
        #expect(SparkleTestGate.currentHolder == nil, "the gate stayed locked after a throw")
        try await SparkleTestGate.run("a later test", timeout: 1.0) { }
    }

    @Test("An ordinary holder is not penalised for being slow")
    func aSlowButFinishingHolderIsFine() async throws {
        // The bound exists to catch a holder that will NEVER finish. Under the
        // full suite 214 tests already report 60s or more, almost all of it
        // queueing rather than working, so a gate that punished slowness would
        // fail honest tests constantly.
        try await SparkleTestGate.run("a slow but honest holder", timeout: 5.0) {
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        #expect(SparkleTestGate.currentHolder == nil)
    }
}
