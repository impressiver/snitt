// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Cross-suite serialization for tests that construct or drive a real
/// `SPUUpdater` — directly, or indirectly through `UpdaterController`'s
/// `SPUStandardUpdaterController`, but only where that construction actually
/// starts Sparkle's machinery (`UpdaterController.init` is deliberately
/// side-effect-free until `.start()` is called, so a test that only
/// constructs one to read back a setting without starting it is NOT in this
/// hazard class — see `SettingsWindowTests.swift`/`WindowLifetimeTests.swift`,
/// neither of which needs this gate for exactly that reason).
///
/// `AppcastTests.swift`, `UpdaterControllerTests.swift`, and
/// `BundleLayoutTests.swift` each drive a real Sparkle updater against a
/// real (loopback or fixture) host, as plain top-level `@Test` functions —
/// none of the three is even a `@Suite`, let alone `.serialized`, and
/// `.serialized` would not have been enough on its own anyway: it only
/// orders tests WITHIN one suite, and swift-testing runs different suites
/// (or, here, different files' top-level tests) concurrently by default.
/// Sparkle's updater carries XPC services, an update-cycle scheduler
/// (`SPUUpdaterCycle`), and shared `UserDefaults` keys
/// (`SUEnableAutomaticChecks`, `SULastCheckTime`, `SUSendProfileInfo` — the
/// last two read/written straight against `UserDefaults.standard` by
/// `UpdaterControllerTests.swift`'s `updaterHonoursTheSetting`, since
/// `Bundle.main` has no identifier under `swift test` and `SUHost` falls
/// back to the standard domain). Several of these running unserialized at
/// once is the same contention class that made window tests flake in M5c
/// (`EditorWindowTestGate`, `Sources/SnittApp/EditorWindowController.swift`),
/// one level up: a scheduler callback or a delegate completion belonging to
/// one suite's updater landing while another suite's updater is mid
/// construct-start-wait-assert.
///
/// Root-caused, not just suspected: `sparkleParsesTheGeneratedFeed`
/// (`AppcastTests.swift`) failed intermittently under the FULL suite —
/// always timing out its 60s `waitUntil` with `delegate.appcast` still nil
/// and a trustworthy summary line present (a timed-out `#require`, not a
/// crash) — while passing every time under `swift test --filter
/// AppcastTests` alone. Reproduced on demand by saturating every CPU
/// (`yes > /dev/null` × `hw.ncpu`) before running the full suite: the
/// starved run failed this exact test after a ~73s wait, with exactly one
/// issue in the whole 615-test run, confirming the failure is contention on
/// a shared resource under load, not a different or new defect.
///
/// A second gate, not a reuse of `EditorWindowTestGate`: that gate protects
/// an entirely different shared resource (`EditorWindowController`'s
/// process-global open-window counter). Routing Sparkle-driving tests
/// through it would serialize them against every editor-window test in the
/// suite for a reason unconnected to this hazard, slowing the run without
/// fixing anything; a dedicated gate keeps each mutex scoped to the
/// contention it actually exists to prevent.
///
/// Lives here — a shared, non-`Tests`-suffixed file in the `SnittAppTests`
/// target, the same convention `SyntheticMovie.swift` already uses — rather
/// than alongside `UpdaterController` in `Sources/SnittApp`: two of the
/// three affected files, `AppcastTests.swift` and `BundleLayoutTests.swift`,
/// drive Sparkle and shell scripts directly and otherwise have no
/// dependency on the `SnittApp` module at all. Anchoring this in
/// `Sources/SnittApp` would force an unrelated `@testable import SnittApp`
/// into both, just to reach a test-only mutex, and would ship test-only code
/// inside the shipping app target for no reason `EditorWindowTestGate`
/// actually has (that gate's `EditorWindowController.openWindowCount`, the
/// resource it's guarding, already lives in `Sources/SnittApp` for
/// production reasons — this gate's resource, Sparkle's own updater state,
/// does not belong to any Snitt production type). All three affected files
/// already compile into this one test target, where an internal
/// (non-`private`) type declared in any one file is visible from the others
/// with no import needed.
///
/// `@MainActor`, not a separate `actor`, matching `EditorWindowTestGate`'s
/// own rationale: every Sparkle-driving test body here already runs on
/// `@MainActor` (Sparkle's `SPUUpdaterDelegate`/`SPUUserDriver` callbacks are
/// main-actor-isolated), and `body` closures capture MainActor-isolated,
/// non-`Sendable` state (delegates, `SPUUpdater` itself). Routing through a
/// distinct actor would require SENDING that closure across an isolation
/// boundary — exactly the `Sendable`-crossing error `-strict-concurrency
/// =complete` exists to catch — for no benefit, since there is only ever one
/// MainActor to contend for anyway.
/// **Bounded, deliberately.** The first version's `acquire()` waited on a
/// `CheckedContinuation` with no ceiling, which made a single stuck holder
/// hang every other gated test — and therefore the whole run — with no
/// output and no diagnostic. That is exactly what happened on 2026-09-09: a
/// full-suite run sat at 0% CPU for over ten minutes, and the only way to
/// learn anything was to `sample` the process by hand.
///
/// A test gate must convert a hang into a FAILURE. A failure names the
/// culprit and lets the other 1142 tests finish; a hang tells you nothing and
/// costs the whole run. Note which direction the risk runs: an over-tight
/// bound produces a flaky failure that is loud and obvious, while an unbounded
/// wait produces silence indistinguishable from ordinary slow progress.
@MainActor
enum SparkleTestGate {
    /// How long a test may WAIT for the gate before giving up.
    ///
    /// Generous on purpose. Under the full suite 214 tests already report 60s
    /// or more — almost all of it queueing behind gates like this one rather
    /// than working — so a tight ceiling here would fail honest tests. This
    /// exists to catch a holder that will never finish, not a slow one.
    static let acquireTimeout: TimeInterval = 300

    /// How long a test may HOLD the gate before it is declared stuck.
    ///
    /// Smaller than `acquireTimeout` so the holder is blamed before its
    /// waiters give up — otherwise every queued test fails and the one
    /// actually at fault looks identical to them.
    static let holdTimeout: TimeInterval = 240

    struct Timeout: Error, CustomStringConvertible {
        let description: String
    }

    private static var locked = false
    private static var holderDescription = "none"

    /// Whether the gate is currently held, and by whom. Exists for the gate's
    /// OWN test, which must wait for its holder to really acquire before
    /// testing what a waiter does — otherwise it races the real Sparkle tests
    /// that share this gate and blames the wrong holder.
    static var currentHolder: String? { locked ? holderDescription : nil }

    /// Polls rather than queueing on a continuation.
    ///
    /// A `CheckedContinuation` must be resumed exactly once, which makes
    /// racing it against a deadline fiddly and easy to get wrong in a way that
    /// crashes the test process. Polling on `@MainActor` is uninteresting by
    /// comparison: `Task.sleep` yields the actor, so the holder runs. FIFO
    /// fairness is lost and no test needs it.
    private static func acquire(for label: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while locked {
            if Date() >= deadline {
                throw Timeout(description: """
                    "\(label)" waited \(Int(acquireTimeout))s for SparkleTestGate and gave up.                     It was held by "\(holderDescription)", which never released it — that holder                     is the defect, not this test.
                    """)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        locked = true
        holderDescription = label
    }

    private static func release() {
        locked = false
        holderDescription = "none"
    }

    /// Runs `body` with the gate held for its ENTIRE duration — the whole
    /// construct-start-wait-assert critical section a Sparkle-driving test
    /// cares about, not just the moment `SPUUpdater` is created.
    ///
    /// `label` defaults to the calling function, so a timeout message names a
    /// real test without anyone having to remember to pass a string.
    static func run<T>(_ label: String = #function,
                       timeout: TimeInterval = acquireTimeout,
                       _ body: () async throws -> T) async throws -> T {
        try await acquire(for: label, timeout: timeout)
        defer { release() }
        return try await body()
    }
}
