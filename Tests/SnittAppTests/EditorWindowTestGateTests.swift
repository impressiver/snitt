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
        // Acquired from a separate task, which may itself queue behind a real
        // windowed test — hence polling `currentHolder` rather than assuming
        // immediate acquisition. Without that, this test would race the ten
        // files that share this gate and blame whichever held it.
        let holder = Task { @MainActor in
            try await EditorWindowTestGate.run("a deliberately stuck holder") {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        defer { holder.cancel() }

        while EditorWindowTestGate.currentHolder != "a deliberately stuck holder" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let started = Date()
        do {
            try await EditorWindowTestGate.run("the waiter", timeout: 0.3) { }
            Issue.record("the waiter acquired a gate that was held — it should have timed out")
        } catch let timeout as EditorWindowTestGate.Timeout {
            // Naming the HOLDER is the point. When this fires for real, every
            // queued windowed test fails at once and the only useful question
            // is which one never let go.
            #expect(timeout.description.contains("a deliberately stuck holder"),
                    "the timeout does not name the holder: \(timeout.description)")
        }

        let waited = Date().timeIntervalSince(started)
        #expect(waited < 3.0, "the waiter took \(waited)s to give up on a 0.3s timeout")

        _ = await holder.result
    }

    @Test("The gate is released after a body throws, not left locked forever")
    func aThrowingBodyStillReleasesTheGate() async throws {
        struct Boom: Error {}
        do {
            try await EditorWindowTestGate.run("a throwing body") { throw Boom() }
            Issue.record("the body's error was swallowed")
        } catch is Boom {
            // expected
        }
        // Dropping `defer { release() }` would strand the gate: every windowed
        // test after the first failure would then fail too, which is how one
        // defect becomes fifty.
        #expect(EditorWindowTestGate.currentHolder == nil, "the gate stayed locked after a throw")
        try await EditorWindowTestGate.run("a later test", timeout: 1.0) { }
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
        try await EditorWindowTestGate.run("a slow but honest holder", timeout: 30.0) {
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        #expect(EditorWindowTestGate.currentHolder == nil)
    }
}
