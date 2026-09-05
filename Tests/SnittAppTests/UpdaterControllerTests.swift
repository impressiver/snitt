import Testing
import Foundation
import Sparkle
@testable import SnittApp

private let updatesApp = URL(fileURLWithPath: "build/Snitt.app")
private let updatesAppIsBuilt = FileManager.default.fileExists(atPath: updatesApp.path)
private let updatesRequireAppBundle = ProcessInfo.processInfo.environment["SNITT_REQUIRE_APP_BUNDLE"] == "1"
private let updatesAppBundleSkipReason: Comment = "run ./Scripts/make-app.sh first (or set SNITT_REQUIRE_APP_BUNDLE=1 to fail instead of skip)"

@MainActor
@Test("The updater starts with automatic checks matching the setting")
func updaterHonoursTheSetting() {
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
/// automatic checks are off and Sparkle decides not to arrange one at all.
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

/// Lets the `dispatch_async`-based hop between `-[SPUUpdater startUpdater:]`
/// and its scheduling decision run. `RunLoop.main.run(until:)` does NOT do
/// this inside a synchronous `@MainActor @Test` body — verified directly: a
/// bare `DispatchQueue.main.async { fired = true }` followed by pumping the
/// run loop that way left `fired` false after a full second, in this exact
/// harness. `Task.sleep` does drain it (same probe, `fired` true after
/// 0.5s) — the main actor's executor interleaves with `DispatchQueue.main`
/// across a suspension point even though nothing here calls `NSApp.run()`.
@MainActor
private func letMainQueueDrain(for seconds: TimeInterval) async throws {
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

@MainActor
@Test(
    "A fresh install's default setting genuinely schedules no automatic check — not merely reads false",
    .enabled(if: updatesAppIsBuilt || updatesRequireAppBundle, updatesAppBundleSkipReason)
)
func freshInstallSchedulesNoAutomaticCheck() async throws {
    try #require(updatesAppIsBuilt, updatesAppBundleSkipReason)

    // Verified this fails against the wrong implementation it exists to
    // catch: temporarily flipping `UpdateSettings.init`'s default to `true`
    // turned the recorded event into `.willSchedule` instead of
    // `.willNotSchedule` — a boolean-only test would not have caught this,
    // since nothing here reads a settings struct back. Restoring `false`
    // passed again. See task-3-report.md.
    //
    // R3's actual discriminator: `updaterHonoursTheSetting` proves
    // `UpdaterController` forwards the setting to
    // `SPUUpdater.automaticallyChecksForUpdates`; this proves that property,
    // once false, genuinely prevents Sparkle's own scheduler from arranging
    // a check — rather than trusting that a read-back boolean implies
    // nothing happens. Drives the real `SPUUpdater` against the built
    // bundle (the same object `UpdaterController` wraps), since
    // `SPUStandardUpdaterController` always targets `Bundle.main`, which in
    // this process is the test host, not `build/Snitt.app`.
    //
    // Deliberately does NOT test toggling automatic checks ON here: with no
    // prior check ever recorded, Sparkle's scheduler treats the very first
    // run as "overdue" and fires a REAL background check immediately rather
    // than merely scheduling one — and this bundle's Info.plist domain
    // (`com.impressiver.snitt`, since the host bundle differs from the test
    // process's own `Bundle.main`) is the same preference domain a real
    // installed Snitt.app would use. Exercising the ON path safely would
    // mean seeding a fake last-check date into that real domain, which is a
    // worse side effect than the gap it would close. The off-then-on
    // direction is covered by `updaterHonoursTheSetting`; the "turning it
    // off cancels an already-pending check" half of Ruling R3 is NOT
    // exercised live here — verified instead by reading Sparkle 2.6's
    // `SPUUpdater.m`: `automaticallyChecksForUpdates`'s setter posts
    // `SUUpdateAutomaticCheckSettingChangedNotification`, whose handler
    // (`updateAutomaticCheckSettingChanged:`) calls
    // `resetUpdateCycleAfterShortDelay`, which calls `cancelNextUpdateCycle`
    // — `cancelPreviousPerformRequestsWithTarget:` against the pending
    // scheduled check — before scheduling anew from the current setting.
    // That is a real code-reading verification, not an executable one; flagged
    // here rather than dressed up as tested.
    let bundle = try #require(Bundle(url: updatesApp), "could not open build/Snitt.app as a bundle")
    let spy = SchedulingSpy()
    let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
                             userDriver: UpdatesNoopUserDriver(), delegate: spy)
    updater.automaticallyChecksForUpdates = UpdateSettings().automaticChecksEnabled
    try updater.start()

    try await letMainQueueDrain(for: 1.0)

    #expect(spy.events == [.willNotSchedule], "a fresh install must not schedule an automatic check: \(spy.events)")
}
