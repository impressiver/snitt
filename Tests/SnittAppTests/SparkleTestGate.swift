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
@MainActor
enum SparkleTestGate {
    private static var locked = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    private static func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private static func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Runs `body` with the gate held for its ENTIRE duration — the whole
    /// construct-start-wait-assert critical section a Sparkle-driving test
    /// cares about, not just the moment `SPUUpdater` is created.
    static func run<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}
