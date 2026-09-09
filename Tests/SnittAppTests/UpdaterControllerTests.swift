// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
import Sparkle
@testable import SnittApp

@MainActor
@Test("The updater starts with automatic checks matching the setting")
func updaterHonoursTheSetting() async throws {
    // `SparkleTestGate` (Tests/SnittAppTests/SparkleTestGate.swift):
    // `UpdaterController.init` constructs a real `SPUStandardUpdaterController`
    // (and, below, mutates its live `SPUUpdater.automaticallyChecksForUpdates`,
    // which Sparkle persists straight into the REAL `UserDefaults.standard`
    // domain — see the comment on the `defer` just below). `AppcastTests.swift`
    // and this file's other two tests each drive a real `SPUUpdater` too, as
    // unserialized top-level tests, so without this gate this test's reads
    // and writes of shared Sparkle state can interleave with theirs.
    try await SparkleTestGate.run {
        // `SPUStandardUpdaterController` always targets `Bundle.main`, which in
        // this process has no real bundle identifier, so `SUHost` falls back to
        // `NSUserDefaults.standardUserDefaults` (R20/finding 7 — the reviewer
        // found this leaves `SUEnableAutomaticChecks`/`SUSendProfileInfo` behind
        // in `~/Library/Preferences/swiftpm-testing-helper.plist`). Clean up
        // afterwards rather than leaving that state for the next run.
        defer {
            UserDefaults.standard.removeObject(forKey: "SUEnableAutomaticChecks")
            UserDefaults.standard.removeObject(forKey: "SUSendProfileInfo")
        }

        // The discriminating case: a controller that constructs Sparkle with its
        // own defaults ignores the user's choice entirely, and nothing else here
        // would notice.
        //
        // Verified this fails against the wrong implementation it exists to
        // catch: hardcoding `automaticallyChecksForUpdates = false` in
        // `UpdaterController.init` regardless of the passed-in setting made the
        // second assertion below fail (`on.automaticChecksEnabled` read false);
        // restoring the real assignment passed. See task-3-report.md.
        let off = UpdaterController(settings: UpdateSettings(automaticChecksEnabled: false))
        #expect(off.automaticChecksEnabled == false)
        let on = UpdaterController(settings: UpdateSettings(automaticChecksEnabled: true))
        #expect(on.automaticChecksEnabled)

        // R22: the two tests above are not complementary the way a first pass
        // at this file claimed. `SPUStandardUpdaterController` always targets
        // `Bundle.main`, and this process has no bundle identifier, so `SUHost`
        // resolves to `NSUserDefaults.standardUserDefaults` here (same reason
        // the `defer` above exists) — which makes Sparkle's own PERSISTED write
        // directly observable, and that is what actually pins the setter, not
        // a read-back through `UpdaterController` itself.
        //
        // Verified against the exact wrong implementation this exists to catch:
        // an `UpdaterController` whose `automaticChecksEnabled` setter writes
        // only to a private cached var (with `init` still forwarding to
        // `SPUUpdater.automaticallyChecksForUpdates` directly, not through the
        // setter) passes `off`/`on` above — `on` was constructed with `true`,
        // so line 53 is satisfied by `init`'s own forwarding — AND is invisible
        // to `turningOffCancelsAPendingCheck` (which drives a raw `SPUUpdater`
        // and never touches `UpdaterController` at all). Re-ran this exact
        // mutant to record real output rather than a different run's: full
        // suite `Test run with 470 tests in 8 suites failed after 42.134
        // seconds with 1 issue`, the one issue at THIS line —
        // `Expectation failed: (UserDefaults.standard.object(forKey:
        // "SUEnableAutomaticChecks") as? Bool → true) == false`, i.e. the
        // `= false` write on the line below never reached Sparkle. Restoring
        // the real forwarding passes both directions and the full 470 again.
        on.automaticChecksEnabled = true
        #expect(UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool == true)
        on.automaticChecksEnabled = false
        #expect(UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool == false)
    }
}

/// A `SPUUserDriver` that does nothing. Duplicated from
/// `BundleLayoutTests.swift`'s `NoopUserDriver` (private to that file)
/// rather than shared, so this file's Sparkle-scheduling concerns stay
/// independent of that file's signing/configuration concerns.
@MainActor
private final class UpdatesNoopUserDriver: NSObject, SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {}
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {}
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {}
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {}
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {}
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {}
    func dismissUpdateInstallation() {}
}

/// Records Sparkle's own scheduling verdicts — `willSchedule` fires when a
/// background check gets timed for later, `willNotSchedule` fires when
/// Sparkle decides not to arrange one at all (automatic checks off, or a
/// setting change just cancelled one already pending).
@MainActor
private final class SchedulingSpy: NSObject, SPUUpdaterDelegate {
    private(set) var events: [UpdaterController.ScheduleEvent] = []
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        events.append(.willSchedule)
    }
    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {
        events.append(.willNotSchedule)
    }
}

/// Polls `condition` instead of sleeping a fixed duration, up to `timeout`,
/// so a `dispatch_async`-based hop or an NSTimer-based
/// `performSelector:afterDelay:` gets a chance to run. Verified both need
/// `await Task.sleep`, not `RunLoop.main.run(until:)`: a bare
/// `DispatchQueue.main.async` probe and a `perform(_:afterDelay:)` probe,
/// each pumped via `RunLoop.main.run(until:)` inside a synchronous
/// `@MainActor @Test` body in this harness, left their flags false after a
/// full second — even though `Thread.isMainThread` is true there — while
/// the same two probes under `Task.sleep` both fired. The main actor's
/// executor interleaves with `DispatchQueue.main`/the run loop across a
/// suspension point even though nothing here calls `NSApp.run()`.
///
/// Polling rather than a fixed sleep matters under the full suite: many
/// other `@MainActor` tests contending for the same main-actor
/// executor/main dispatch queue can push what is normally a ~1-second hop
/// well past a second of wall-clock time. A fixed `Task.sleep(for: 1.0)`
/// here was observed to fail intermittently under `swift test`'s full
/// parallel run for exactly that reason; this returns the moment the
/// condition is met and only gives up after a generous timeout, so it
/// stays fast when uncontended and tolerant when not.
@MainActor
/// Polls `condition` until it holds or `timeout` elapses.
///
/// 180s, raised from 60 on 2026-09-07. The waits guarded by this are real
/// `SPUUpdater` scheduler and XPC round-trips, whose latency scales with machine
/// load rather than with anything the assertion is about. The 60s ceiling was
/// calibrated before the suite gained waveform and filmstrip sampling — tests
/// that read every audio sample and decode video frames — and after that both
/// this file's updater tests and `AppcastTests` began timing out at ~64s in
/// full-suite runs while passing in isolation in under a second.
///
/// `SparkleTestGate` already serialises updater tests against EACH OTHER; it
/// cannot serialise them against the rest of the suite. Raising the ceiling
/// changes only how long we wait for a real answer, never what counts as one —
/// a feed that genuinely fails to parse still fails, just later.
private func waitUntil(timeout: TimeInterval = 180, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}

/// A hand-built, unsigned `.app` fixture whose Info.plist points Sparkle's
/// own preference storage at a private `SUDefaultsDomain` suite instead of
/// the fixture's own bundle identifier.
///
/// This is the fix for R16/R17/R19: `SUHost.initWithBundle:` (`SUHost.m`)
/// reads `SUDefaultsDomain` from Info.plist BEFORE falling back to the
/// bundle identifier, so every read and write Sparkle performs when driven
/// against this bundle (`SUHasLaunchedBefore`, `SUEnableAutomaticChecks`,
/// `SULastCheckTime`, …) lands in a throwaway suite this fixture owns and
/// deletes — never in `com.impressiver.snitt`, the domain a real installed
/// Snitt uses. `build/Snitt.app` (this repo's actual output) has no such
/// override, which is exactly why driving it directly, as the first version
/// of this test did, wrote into that real domain — confirmed independently
/// via `defaults read com.impressiver.snitt` before and after.
///
/// Also carries a well-formed (but meaningless — 32 zero bytes) EdDSA
/// public key so `checkIfConfiguredProperlyAndRequireFeedURL:` accepts an
/// unsigned fixture bundle without needing Apple code-signature validation,
/// which an ad-hoc temp-directory bundle has none of. Note per the review's
/// correction: a MISSING key does not make Sparkle reject anything — on an
/// https feed with a code-signed bundle it falls through to
/// signature-only validation. This fixture supplies a key purely to satisfy
/// that check without also having to codesign a throwaway bundle; it has
/// nothing to do with rejection.
@MainActor
private struct SparkleFixture {
    let bundle: Bundle
    private let root: URL
    private let defaultsSuite: String

    /// Captured once, on first use — before either fixture-creating test
    /// can possibly have written a plist — so the sweep below has a fixed
    /// point to compare against rather than "now" (which would race
    /// whichever fixture is concurrently live).
    private static let processStartTime = Date()

    /// Deletes any `com.snitt.test.fixture.*.plist` OLDER than this
    /// process's own start time — i.e. left behind by an earlier `swift
    /// test` invocation, never by this one — from `~/Library/Preferences`.
    /// `cleanUp()`'s own best-effort retry closes the common case, but
    /// `cfprefsd` can flush a domain's dirty state well after that process
    /// has already exited — outside anything an in-process retry can catch
    /// (observed: stray files still appear occasionally even with a
    /// bounded retry under the full suite's parallel load). Without this
    /// sweep that is unbounded growth, one file per leaked run, forever;
    /// with it, the namespace is swept clean at the start of every run
    /// regardless of what the previous run left behind.
    ///
    /// R24: the `processStartTime` cutoff (rather than sweeping
    /// unconditionally) is what keeps this safe against the *other*
    /// fixture-creating test's file being live in the SAME run. Both
    /// `freshInstallSchedulesNoAutomaticCheck` and
    /// `turningOffCancelsAPendingCheck` are `@MainActor` but both `await`
    /// inside `waitUntil` (`Task.sleep`), which releases the main actor —
    /// so `make()` from one can genuinely run while the other's fixture is
    /// still live and polling. An unconditional sweep would be able to
    /// delete the live fixture's `SULastCheckTime`-seeded suite out from
    /// under it — the harm mode that matters is R19's: falling into
    /// Sparkle's "overdue, check right now" branch, i.e. a real,
    /// unrequested network request, the one thing this task exists to
    /// prevent. A file this process itself creates always has a
    /// modification date after `processStartTime` (captured before any
    /// fixture in this process has been made), so it can never match
    /// `< processStartTime` and can never be swept by either test in this
    /// process, regardless of scheduling order. This closes the reachable,
    /// same-process interleaving deterministically — it does not depend on
    /// timing luck, only on `processStartTime` having been captured first,
    /// which happens automatically. It does not close two literally
    /// concurrent `swift test` PROCESSES on one machine: a second process
    /// starting after the first has already written a fixture, but before
    /// that fixture's owning test has finished, would see a file older
    /// than ITS OWN `processStartTime` and could still sweep it. I did not
    /// attempt to close that case — it needs a cross-process lock, which
    /// is disproportionate here — and I did not reproduce it, so I am not
    /// claiming it is fixed, only that the concretely reachable
    /// same-process race is.
    private static func sweepStaleFixtureFiles() {
        guard let preferencesDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Preferences") else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: preferencesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in contents where file.lastPathComponent.hasPrefix("com.snitt.test.fixture.") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            // A file whose modification date can't be read is left alone,
            // not swept: the asymmetry in R19 is that leaking a stray
            // 42-byte plist is harmless, while deleting a live fixture's
            // backing file risks the one thing this task exists to
            // prevent, so an unreadable date errs toward not deleting.
            guard let modified, modified < processStartTime else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// `seedLastCheckTime`: when automatic checks will be turned on,
    /// Sparkle treats an absent `SULastCheckTime` as `NSDate.distantPast`
    /// and takes its "we're overdue, check right now" branch — a REAL
    /// background check, not a scheduled one (`SPUUpdater.m`,
    /// `scheduleNextUpdateCheckFiringImmediately:usingCurrentDate:`). R19:
    /// the original cancellation-path reasoning depended on
    /// `com.impressiver.snitt` already having a recent `SULastCheckTime`
    /// from real manual testing on this machine — state a fresh CI checkout
    /// does not have, where the same code path reaches the network instead.
    /// Seeding this fixture's own (private, disposable) suite with "now"
    /// makes the scheduled-for-later branch the one actually exercised,
    /// deterministically, on any machine.
    static func make(seedLastCheckTime: Bool) throws -> SparkleFixture {
        sweepStaleFixtureFiles()
        let suite = "com.snitt.test.fixture.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnittSparkleFixture-\(UUID().uuidString).app")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        let meaninglessPublicKey = Data(count: 32).base64EncodedString()
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.snitt.test.fixture",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            // Loopback, not `https://example.invalid`. These are unit tests about
            // SCHEDULING — they read `willSchedule`/`willNotSchedule` off a spy
            // delegate and never assert on a feed's contents — so they have no
            // business resolving a hostname at all. `.invalid` is reserved and
            // normally NXDOMAINs in milliseconds (measured: 0.02s), but it is
            // still a real DNS round trip that a captive portal, a VPN, or a
            // hijacking resolver can stall. Port 9 on loopback refuses
            // instantly and involves no resolver.
            "SUFeedURL": "http://127.0.0.1:9/appcast.xml",
            "SUPublicEDKey": meaninglessPublicKey,
            // Matches the real built bundle's cold-start default (Ruling
            // R3) so `startUpdateCycle`'s permission-prompt branch is
            // deterministically skipped here too, regardless of this
            // fixture's own "has launched before" state.
            "SUEnableAutomaticChecks": false,
            "SUDefaultsDomain": suite,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        if seedLastCheckTime {
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.set(Date(), forKey: "SULastCheckTime")
        }

        let bundle = try #require(Bundle(url: root), "could not open the Sparkle test fixture as a bundle")
        return SparkleFixture(bundle: bundle, root: root, defaultsSuite: suite)
    }

    func cleanUp() {
        // R23: `removePersistentDomain(forName:)` only empties the suite in
        // memory — `NSUserDefaults`/`CFPreferences` flushes dirty domains to
        // disk lazily, so deleting `<suite>.plist` right after
        // `removePersistentDomain` races a pending flush of THIS fixture's
        // own earlier `set(...)` call and can lose: the flush lands after
        // the delete and leaves a fresh, empty 42-byte plist behind
        // (observed accumulating, one per fixture, forever, on a persistent
        // developer machine). `synchronize()` forces that flush to happen
        // NOW, before we delete, closing the race — verified empirically:
        // without it, files reliably survive a full `swift test` run;
        // with it, they don't.
        let defaults = UserDefaults(suiteName: defaultsSuite)
        defaults?.removePersistentDomain(forName: defaultsSuite)
        defaults?.synchronize()
        if let preferencesURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Preferences")
            .appendingPathComponent("\(defaultsSuite).plist") {
            // `synchronize()` returning is not a guarantee the write already
            // landed on disk — `cfprefsd` can flush a couple of
            // milliseconds later via its own XPC round trip, especially
            // under the full suite's parallel load, occasionally recreating
            // an empty file just after a single delete attempt (observed).
            // A short bounded retry closes that window.
            //
            // R37 (task-5-review.md): delete, then wait once and check —
            // if the file is still gone after that one window, stop; only
            // an actual recreation costs a further cycle. Without this
            // early exit, every invocation paid the full 9×50ms
            // regardless of whether the race ever fired, which
            // contradicted this comment's own "without adding meaningful
            // time" claim.
            for attempt in 0..<10 {
                try? FileManager.default.removeItem(at: preferencesURL)
                guard attempt < 9 else { break }
                Thread.sleep(forTimeInterval: 0.05)
                if !FileManager.default.fileExists(atPath: preferencesURL.path) {
                    break
                }
            }
        }
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
@Test("A fresh install's default setting genuinely schedules no automatic check — not merely reads false")
func freshInstallSchedulesNoAutomaticCheck() async throws {
    // `SparkleTestGate` (Tests/SnittAppTests/SparkleTestGate.swift): this
    // test starts a real `SPUUpdater` and polls its delegate for a
    // scheduling verdict — see that file's doc comment for why this must be
    // serialized against `AppcastTests.swift` and this file's other two
    // Sparkle-driving tests, none of which is otherwise gated against the
    // others.
    try await SparkleTestGate.run {
        // Verified this fails against the wrong implementation it exists to
        // catch: temporarily flipping `UpdateSettings.load`'s underlying
        // `defaults.bool(forKey:)` call to `(defaults.object(forKey:) as? Bool)
        // ?? true` (the realistic wrong implementation R20 names — flipping
        // `init`'s default does NOT fail this, since `load` never consults it)
        // turned the recorded event into `.willSchedule` instead of
        // `.willNotSchedule`. A boolean-only test would not have caught this,
        // since nothing here reads a settings struct back. Restoring the real
        // `bool(forKey:)` call passed again. See task-3-report.md.
        let fixture = try SparkleFixture.make(seedLastCheckTime: false)
        defer { fixture.cleanUp() }

        let spy = SchedulingSpy()
        let updater = SPUUpdater(hostBundle: fixture.bundle, applicationBundle: fixture.bundle,
                                 userDriver: UpdatesNoopUserDriver(), delegate: spy)
        // R20: through `UpdateSettings.load()` on a genuinely fresh, empty
        // suite — the actual production seam — not `UpdateSettings()`'s init
        // default directly. Closes the gap the reviewer identified: the two
        // were previously covered by separate tests that never touched each
        // other.
        let freshDefaults = try #require(UserDefaults(suiteName: "snitt.updates.fresh.\(UUID().uuidString)"))
        updater.automaticallyChecksForUpdates = UpdateSettings.load(freshDefaults).automaticChecksEnabled
        try updater.start()

        // `willNotSchedule` fires synchronously within the single
        // `dispatch_async` hop `startUpdater:` schedules — 10s is generous
        // headroom for that hop under the full suite's parallel load, not an
        // expected wait.
        try await waitUntil { !spy.events.isEmpty }

        #expect(spy.events == [.willNotSchedule], "a fresh install must not schedule an automatic check: \(spy.events)")
    }
}

@MainActor
@Test("Turning automatic checks off genuinely cancels a check that was already scheduled")
func turningOffCancelsAPendingCheck() async throws {
    // `SparkleTestGate` (Tests/SnittAppTests/SparkleTestGate.swift): same
    // reason as `freshInstallSchedulesNoAutomaticCheck` above — a real
    // `SPUUpdater`, scheduling state polled from its delegate, unserialized
    // against the other Sparkle-driving suites without this gate.
    try await SparkleTestGate.run {
        // The distinguishing case R3 calls out explicitly: an implementation
        // that merely stops SCHEDULING NEW checks while leaving an
        // already-pending one alone would still show `.willSchedule` as the
        // last recorded event here. `UpdaterController` does no scheduling of
        // its own — it only forwards to `SPUUpdater.automaticallyChecksForUpdates`
        // — so this is really proving Sparkle's own behaviour, but it's exactly
        // the behaviour `UpdaterController.automaticChecksEnabled`'s setter
        // relies on, and the reviewer's fixture technique makes it safe to
        // observe directly instead of trusting the framework doc's word for it.
        let fixture = try SparkleFixture.make(seedLastCheckTime: true)
        defer { fixture.cleanUp() }

        let spy = SchedulingSpy()
        let updater = SPUUpdater(hostBundle: fixture.bundle, applicationBundle: fixture.bundle,
                                 userDriver: UpdatesNoopUserDriver(), delegate: spy)
        updater.automaticallyChecksForUpdates = true
        try updater.start()

        try await waitUntil { !spy.events.isEmpty }
        try #require(spy.events == [.willSchedule],
                     "setup precondition failed: a check must be pending before we can prove turning it off cancels it — got \(spy.events)")

        updater.automaticallyChecksForUpdates = false
        // Sparkle's reset-cycle delay (`SPUUpdaterCycle.resetUpdateCycleAfterDelay`)
        // is a hardcoded 1 second on top of Sparkle's own scheduling hop; poll
        // rather than sleeping a fixed window, since either can be pushed well
        // past a second of wall-clock time under the full suite's parallel load.
        try await waitUntil { spy.events.count >= 2 }

        #expect(spy.events == [.willSchedule, .willNotSchedule],
                "turning automatic checks off must cancel the pending check, not merely stop scheduling new ones: \(spy.events)")
    }
}
