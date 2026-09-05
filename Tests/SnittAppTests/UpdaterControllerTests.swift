import Testing
import Foundation
import Sparkle
@testable import SnittApp

@MainActor
@Test("The updater starts with automatic checks matching the setting")
func updaterHonoursTheSetting() {
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
private func waitUntil(timeout: TimeInterval = 60, _ condition: () -> Bool) async throws {
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
            "SUFeedURL": "https://example.invalid/appcast.xml",
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
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
@Test("A fresh install's default setting genuinely schedules no automatic check — not merely reads false")
func freshInstallSchedulesNoAutomaticCheck() async throws {
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

@MainActor
@Test("Turning automatic checks off genuinely cancels a check that was already scheduled")
func turningOffCancelsAPendingCheck() async throws {
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
