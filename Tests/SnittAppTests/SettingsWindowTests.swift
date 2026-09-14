// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
@testable import SnittApp

/// Covers §4.14's Settings window (Command-comma). The window consolidates
/// four settings that accumulated as status-item toggles across M2b–M5b;
/// these tests exist to pin the constraint that both surfaces read and write
/// the SAME `UserDefaults` keys, not two independently-correct stores.
@Suite(.serialized)
@MainActor
struct SettingsWindowTests {
    init() { _ = NSApplication.shared }

    private func fixtureDefaults() throws -> (UserDefaults, String) {
        let suiteName = "com.snitt.test.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    @Test("Every setting defaults to off in a clean domain")
    func settingsDefaultOff() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AgentSettings.load(defaults).agentRecordingEnabled == false)
        #expect(AgentSettings.load(defaults).unattendedRecordingEnabled == false)
        #expect(EventLoggingSettings.load(defaults).enabled == false)
        #expect(MicrophoneSettings.load(defaults).enabled == false)
        #expect(UpdateSettings.load(defaults).automaticChecksEnabled == false)
        #expect(CrashReportSettings.load(defaults).enabled == false)
    }

    @Test("A corrupt stored value reads as off, not on")
    func corruptValueReadsAsOff() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Absent and invalid are DIFFERENT states, and both are not-on.
        // This project has been bitten by silent coercion four times.
        defaults.set("yes please", forKey: "com.impressiver.snitt.eventLoggingEnabled")
        #expect(EventLoggingSettings.load(defaults).enabled == false)
    }

    /// The test that actually exercises `SettingsWindowController`, not just
    /// the settings structs it wraps. A window with its own storage is two
    /// settings wearing one name — the menu says off, the window says on,
    /// and the user cannot tell which the app obeys.
    ///
    /// Verified to fail against the mutation this exists to catch: giving
    /// `SettingsWindowController` its own `UserDefaults(suiteName:)` instead
    /// of using the `defaults` it was handed makes the first `#expect` below
    /// fail — the window shows the checkbox off, because it never looked at
    /// the fixture where `EventLoggingSettings(enabled: true)` was saved.
    @Test("The settings window reads and writes the store it was given, not one of its own")
    func bothSurfacesShareStorage() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }

        // Simulate the status item having already turned event logging on,
        // through the exact same settings type the window will load.
        EventLoggingSettings(enabled: true).save(to: defaults)

        let updater = UpdaterController(settings: UpdateSettings.load(defaults))
        SettingsWindowController.show(updater: updater, defaults: defaults, activate: false)

        let eventLoggingCheckbox = try #require(
            SettingsWindowController.shared?.checkbox(titled: SettingsWindowController.eventLoggingTitle))
        // Proves the window read from the SHARED store: a window with its
        // own storage would show this off.
        #expect(eventLoggingCheckbox.state == .on)

        // Now toggle a DIFFERENT setting inside the window and confirm the
        // write lands in the same shared store, where the status item —
        // built directly on `AgentSettings.load`/`.save` — would see it.
        let agentCheckbox = try #require(
            SettingsWindowController.shared?.checkbox(titled: SettingsWindowController.agentRecordingTitle))
        #expect(agentCheckbox.state == .off)
        agentCheckbox.performClick(nil)
        #expect(AgentSettings.load(defaults).agentRecordingEnabled == true)
    }

    /// R22's shape, aimed at this window specifically: a checkbox that only
    /// writes `UserDefaults` and never forwards to Sparkle reads back
    /// correctly and changes nothing.
    @Test("Toggling automatic updates forwards to UpdaterController, not just UserDefaults")
    func automaticUpdatesRoutesThroughUpdater() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
            // `SPUStandardUpdaterController` always targets `Bundle.main`,
            // which has no real bundle identifier in this process, so
            // `SUHost` falls back to `UserDefaults.standard` — the same
            // leak `UpdaterControllerTests` cleans up.
            UserDefaults.standard.removeObject(forKey: "SUEnableAutomaticChecks")
            UserDefaults.standard.removeObject(forKey: "SUSendProfileInfo")
        }

        let updater = UpdaterController(settings: UpdateSettings(automaticChecksEnabled: false))
        #expect(updater.automaticChecksEnabled == false)

        SettingsWindowController.show(updater: updater, defaults: defaults, activate: false)
        let checkbox = try #require(
            SettingsWindowController.shared?.checkbox(titled: SettingsWindowController.automaticUpdatesTitle))
        checkbox.performClick(nil)

        #expect(UpdateSettings.load(defaults).automaticChecksEnabled == true)
        #expect(updater.automaticChecksEnabled == true,
                "a write straight to UserDefaults that bypasses UpdaterController would leave this false — M5b's R22")
    }

    /// Two Settings windows can disagree on screen — a second Command-comma
    /// must focus the one that already exists.
    @Test("A second show() focuses the existing window instead of opening another")
    func secondShowFocusesExistingWindow() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        let updater = UpdaterController(settings: UpdateSettings.load(defaults))

        SettingsWindowController.show(updater: updater, defaults: defaults, activate: false)
        let first = try #require(SettingsWindowController.shared)

        SettingsWindowController.show(updater: updater, defaults: defaults, activate: false)
        let second = try #require(SettingsWindowController.shared)

        #expect(first === second)
    }

    /// Closing the window (rather than a second `show()`) is what clears the
    /// singleton — otherwise a closed window's stale reference would be
    /// focused instead of a fresh one being built.
    ///
    /// Drives this through the `NSWindowDelegate` callback directly rather
    /// than a real `window.close()`: this whole test target runs suites
    /// concurrently, and a real close racing another suite's real window
    /// close (`EditorWindowControllerTests`'s "Closing one of two editors
    /// keeps the other open") reliably crashed the process outside any
    /// `#expect` — `swift test` reported exit 0 with no summary line, the
    /// exact silent-segfault shape this project has already been warned
    /// about. Calling the delegate method exercises the identical
    /// production logic (`windowWillClose` clearing `shared`) without the
    /// real AppKit window-close machinery two suites cannot safely share.
    @Test("Closing the window allows a fresh one to be created on the next show()")
    func closingWindowAllowsFreshShow() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        let updater = UpdaterController(settings: UpdateSettings.load(defaults))

        SettingsWindowController.show(updater: updater, defaults: defaults, activate: false)
        let first = try #require(SettingsWindowController.shared)
        first.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: first.window))
        #expect(SettingsWindowController.shared == nil)

        SettingsWindowController.show(updater: updater, defaults: defaults, activate: false)
        let second = try #require(SettingsWindowController.shared)
        #expect(first !== second)
    }

    /// F1: the fix-round finding. A plain `save()` in the window's event-
    /// logging toggle skips §4.10's pre-explain and can persist `enabled =
    /// true` with no Input Monitoring grant behind it — the exact state
    /// `AppDelegate`'s original status-item closure was written to avoid
    /// (see its "deliberately NOT persisted" comment). Verified to fail
    /// against that bug: a `toggleEventLogging` body that does
    /// `EventLoggingSettings(enabled: sender.state == .on).save(to:
    /// defaults)` and nothing else makes both `#expect`s below fail — the
    /// checkbox stays on and the setting reads back `true` even though the
    /// injected `eventLoggingToggle` fake reports the grant as refused.
    @Test("The window's event-logging checkbox returns to off when the grant is refused, and nothing is persisted")
    func eventLoggingRevertsWhenGrantRefused() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        let updater = UpdaterController(settings: UpdateSettings.load(defaults))

        // Simulates §4.10's ladder refusing the grant (declined pre-explain,
        // or `InputMonitoringAccess.ensureGranted()` returning false) —
        // without raising the real alert or touching real TCC state.
        SettingsWindowController.show(updater: updater, defaults: defaults, activate: false,
                                      eventLoggingToggle: { _, _ in false })

        let checkbox = try #require(
            SettingsWindowController.shared?.checkbox(titled: SettingsWindowController.eventLoggingTitle))
        #expect(checkbox.state == .off)
        checkbox.performClick(nil)

        #expect(checkbox.state == .off,
                "a refused grant must leave the checkbox unchecked, not showing the click that was refused")
        #expect(EventLoggingSettings.load(defaults).enabled == false,
                "a refused grant must not persist enabled = true")
    }

    /// The success path through the same injection point, so the fake
    /// above is pinned as actually standing in for a real grant rather than
    /// a stub that always returns false regardless of what happened.
    @Test("The window's event-logging checkbox stays on when the grant succeeds")
    func eventLoggingPersistsWhenGrantSucceeds() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        let updater = UpdaterController(settings: UpdateSettings.load(defaults))

        SettingsWindowController.show(updater: updater, defaults: defaults, activate: false,
                                      eventLoggingToggle: { enabled, defaults in
                                          EventLoggingSettings(enabled: enabled).save(to: defaults)
                                          return enabled
                                      })

        let checkbox = try #require(
            SettingsWindowController.shared?.checkbox(titled: SettingsWindowController.eventLoggingTitle))
        checkbox.performClick(nil)

        #expect(checkbox.state == .on)
        #expect(EventLoggingSettings.load(defaults).enabled == true)
    }

    /// Crash reporting has NO other surface any more.
    ///
    /// It used to sit in the status-item menu, whose comment called that item
    /// "the ONLY way a user can ever turn it on — a setting nothing can set is
    /// not a setting". The Settings window made that false and the menu item
    /// was removed, which makes this row the single route to §12's opt-in —
    /// and it had no test at all until the removal went looking for one.
    @Test("The crash-reports checkbox reads the store it was given")
    func crashReportsCheckboxSharesStorage() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }

        CrashReportSettings(enabled: true).save(to: defaults)

        let updater = UpdaterController(settings: UpdateSettings.load(defaults))
        SettingsWindowController.show(updater: updater, defaults: defaults, activate: false)

        let checkbox = try #require(
            SettingsWindowController.shared?.checkbox(titled: SettingsWindowController.crashReportsTitle))
        #expect(checkbox.state == .on)
    }

    /// Clicking it must actually persist — the half a "reads the store" test
    /// cannot see. With the menu item gone there is nothing else that writes
    /// this setting, so a checkbox that toggled visually and stored nothing
    /// would leave §12's opt-in permanently off however many times it was
    /// clicked.
    @Test("Clicking crash reports persists the choice")
    func crashReportsPersists() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }

        #expect(CrashReportSettings.load(defaults).enabled == false)

        let updater = UpdaterController(settings: UpdateSettings.load(defaults))
        SettingsWindowController.show(updater: updater, defaults: defaults, activate: false)
        let checkbox = try #require(
            SettingsWindowController.shared?.checkbox(titled: SettingsWindowController.crashReportsTitle))
        checkbox.performClick(nil)

        #expect(CrashReportSettings.load(defaults).enabled == true,
                "the checkbox changed on screen but stored nothing")
    }

    /// The microphone half of `bothSurfacesShareStorage` — the window must
    /// read the setting the status item already wrote, not a store of its
    /// own. Verified to fail against the mutation that test's own doc
    /// comment names: giving `SettingsWindowController` its own
    /// `UserDefaults(suiteName:)` makes this checkbox show off even though
    /// `MicrophoneSettings(enabled: true)` was saved to the fixture.
    @Test("The microphone checkbox reads the store it was given, not one of its own")
    func microphoneCheckboxSharesStorage() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }

        MicrophoneSettings(enabled: true).save(to: defaults)

        let updater = UpdaterController(settings: UpdateSettings.load(defaults))
        SettingsWindowController.show(updater: updater, defaults: defaults, activate: false)

        let checkbox = try #require(
            SettingsWindowController.shared?.checkbox(titled: SettingsWindowController.microphoneTitle))
        #expect(checkbox.state == .on)
    }

    /// The microphone twin of `eventLoggingRevertsWhenGrantRefused`: a
    /// refused grant must leave the checkbox unchecked and persist nothing.
    /// Verified to fail against a `toggleMicrophone` body that skips
    /// straight to `MicrophoneSettings(enabled:).save(to:)` — both
    /// `#expect`s below would fail, exactly as the event-logging mutation
    /// this mirrors does.
    @Test("The window's microphone checkbox returns to off when the grant is refused, and nothing is persisted")
    func microphoneRevertsWhenGrantRefused() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        let updater = UpdaterController(settings: UpdateSettings.load(defaults))

        SettingsWindowController.show(updater: updater, defaults: defaults, activate: false,
                                      microphoneToggle: { _, _ in false })

        let checkbox = try #require(
            SettingsWindowController.shared?.checkbox(titled: SettingsWindowController.microphoneTitle))
        #expect(checkbox.state == .off)
        checkbox.performClick(nil)

        #expect(checkbox.state == .off,
                "a refused grant must leave the checkbox unchecked, not showing the click that was refused")
        #expect(MicrophoneSettings.load(defaults).enabled == false,
                "a refused grant must not persist enabled = true")
    }

    /// The success path through the same injection point, pinning the fake
    /// above as standing in for a real grant rather than a stub that always
    /// refuses regardless of what happened.
    @Test("The window's microphone checkbox stays on when the grant succeeds")
    func microphonePersistsWhenGrantSucceeds() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        let updater = UpdaterController(settings: UpdateSettings.load(defaults))

        SettingsWindowController.show(updater: updater, defaults: defaults, activate: false,
                                      microphoneToggle: { enabled, defaults in
                                          MicrophoneSettings(enabled: enabled).save(to: defaults)
                                          return enabled
                                      })

        let checkbox = try #require(
            SettingsWindowController.shared?.checkbox(titled: SettingsWindowController.microphoneTitle))
        checkbox.performClick(nil)

        #expect(checkbox.state == .on)
        #expect(MicrophoneSettings.load(defaults).enabled == true)
    }

    // MARK: - Output directory (M5f)

    /// The output-directory row's half of `bothSurfacesShareStorage`/
    /// `microphoneCheckboxSharesStorage`: the window must show whatever is
    /// ALREADY in the shared store, not a value of its own. Verified to fail
    /// against the same mutation those two name: giving
    /// `SettingsWindowController` its own `UserDefaults(suiteName:)` would
    /// show the default here even though a custom directory was saved to
    /// the fixture.
    @Test("The output directory row reads the store it was given, not one of its own")
    func outputDirectoryRowSharesStorage() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }

        let custom = URL(fileURLWithPath: "/Volumes/External/MyRecordings", isDirectory: true)
        OutputDirectorySettings(directory: custom).save(to: defaults)

        let updater = UpdaterController(settings: UpdateSettings.load(defaults))
        SettingsWindowController.show(updater: updater, defaults: defaults, activate: false)

        #expect(SettingsWindowController.shared?.outputDirectoryPathText() == custom.path)
    }

    /// Picking a writable folder persists it to the shared store and updates
    /// the row's own label — the two things a real `NSOpenPanel` selection
    /// would need to do, exercised through `applyOutputDirectory`'s test
    /// seam since a real panel cannot be driven from a test (see
    /// `chooseOutputDirectory`'s own doc comment).
    @Test("Choosing a writable directory persists it and updates the label")
    func choosingWritableDirectoryPersists() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        let updater = UpdaterController(settings: UpdateSettings.load(defaults))
        SettingsWindowController.show(updater: updater, defaults: defaults, activate: false)
        let controller = try #require(SettingsWindowController.shared)

        let chosen = FileManager.default.temporaryDirectory
            .appendingPathComponent("snitt-settings-window-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: chosen) }

        controller.applyOutputDirectory(chosen)

        // Compared by `.path`, not raw `URL` equality — see
        // `OutputDirectorySettings.load`'s own doc comment on why two URLs
        // naming the same folder can otherwise compare unequal.
        #expect(OutputDirectorySettings.load(defaults).directory.path == chosen.path)
        #expect(controller.outputDirectoryPathText() == chosen.path)
    }

    /// The output-directory twin of `microphoneRevertsWhenGrantRefused`: a
    /// folder that fails the writability check must be rejected, alerted,
    /// and must leave the previously stored value (here, the default) in
    /// place — mirroring `RecordingCoordinator.prepareOutputDirectory`'s own
    /// "better to find out now than at finalize" reasoning, one step
    /// earlier, at the moment of picking rather than the moment of
    /// recording.
    ///
    /// Verified to fail against an `applyOutputDirectory` that skips
    /// straight to `OutputDirectorySettings(directory:).save(to:)` without
    /// checking writability first: both `#expect`s below would fail, and
    /// the alert spy would never fire.
    @Test("An unwritable directory is rejected, alerted, and nothing is persisted")
    func choosingUnwritableDirectoryIsRejected() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }

        let unwritable = FileManager.default.temporaryDirectory
            .appendingPathComponent("snitt-settings-window-test-unwritable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: unwritable, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: unwritable.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unwritable.path)
            try? FileManager.default.removeItem(at: unwritable)
        }
        #expect(!FileManager.default.isWritableFile(atPath: unwritable.path),
                "the fixture itself must actually be unwritable, or this test proves nothing")

        var alerted: URL?
        let updater = UpdaterController(settings: UpdateSettings.load(defaults))
        SettingsWindowController.show(updater: updater, defaults: defaults, activate: false,
                                      outputDirectoryUnwritableAlert: { alerted = $0 })
        let controller = try #require(SettingsWindowController.shared)
        let before = OutputDirectorySettings.load(defaults).directory

        controller.applyOutputDirectory(unwritable)

        #expect(alerted == unwritable, "the alert must name the folder that was rejected")
        #expect(OutputDirectorySettings.load(defaults).directory.path == before.path,
                "a rejected folder must not overwrite the previously stored value")
        #expect(controller.outputDirectoryPathText() == before.path,
                "the label must not show a folder that was never actually accepted")
    }
}

/// Unit tests for the extracted §4.10 ladder itself — the single place both
/// the status item and the Settings window now call, so there is one rule
/// instead of two that can drift apart.
@Suite(.serialized)
@MainActor
struct EventLoggingToggleTests {
    init() { _ = NSApplication.shared }

    private func fixtureDefaults() throws -> (UserDefaults, String) {
        let suiteName = "com.snitt.test.eventtoggle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    /// Verified to fail against the bug this whole fix round exists for: a
    /// `apply` body that skips straight to `EventLoggingSettings(enabled:
    /// enabled).save(to: defaults)` without consulting `preExplain` at all
    /// makes the second `#expect` fail — `enabled` reads back `true` even
    /// though `preExplain` here declines.
    @Test("Declining the pre-explain persists nothing and returns false")
    func decliningPreExplainPersistsNothing() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let applied = EventLoggingToggle.apply(true, defaults: defaults,
                                                preExplain: { _ in false },
                                                ensureGranted: { true },
                                                showAlreadyDenied: {})

        #expect(applied == false)
        #expect(EventLoggingSettings.load(defaults).enabled == false)
    }

    /// Same shape, aimed at the grant step rather than the pre-explain step
    /// — a declined pre-explain and a refused grant are different failure
    /// points that must both leave the setting off.
    ///
    /// Found by hand: `apply` used to call `showAlreadyDenied()` on EVERY
    /// refused grant, including the very first one. But
    /// `InputMonitoringAccess.ensureGranted()` returns `false` on the FIRST
    /// ask too, WHILE the user is still looking at the real System Settings
    /// dialog it just raised (same shape as Screen Recording, spike S5) —
    /// so that alert rendered on top of the live system dialog it was
    /// contradicting. This test pins the fix: a first-time refusal
    /// (`hasRequested` reporting `false`) must stay silent, exactly like
    /// `ensureScreenRecordingGrant`'s `.awaitingRelaunch` case.
    @Test("A first-time refused grant persists nothing, returns false, and stays silent")
    func firstRefusedGrantStaysSilent() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var showedAlreadyDenied = false
        var markedRequested = false
        let applied = EventLoggingToggle.apply(true, defaults: defaults,
                                                preExplain: { _ in true },
                                                hasRequested: { false },
                                                markRequested: { markedRequested = true },
                                                ensureGranted: { false },
                                                showAlreadyDenied: { showedAlreadyDenied = true })

        #expect(applied == false)
        #expect(EventLoggingSettings.load(defaults).enabled == false)
        #expect(markedRequested, "the first ask must be recorded so a LATER refusal can be told apart")
        #expect(!showedAlreadyDenied,
                "macOS's own dialog is on screen on the first ask; Snitt's alert must not contradict it")
    }

    /// The other half of the same distinction: once Snitt has already asked
    /// before (`hasRequested` reporting `true`), macOS raises no second
    /// system dialog, so the only way the user learns anything is Snitt's
    /// own alert — this is the one case where showing it is correct.
    @Test("A refusal after an earlier ask persists nothing, returns false, and shows the already-denied alert")
    func repeatRefusedGrantShowsAlreadyDenied() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var showedAlreadyDenied = false
        let applied = EventLoggingToggle.apply(true, defaults: defaults,
                                                preExplain: { _ in true },
                                                hasRequested: { true },
                                                markRequested: {},
                                                ensureGranted: { false },
                                                showAlreadyDenied: { showedAlreadyDenied = true })

        #expect(applied == false)
        #expect(EventLoggingSettings.load(defaults).enabled == false)
        #expect(showedAlreadyDenied,
                "macOS will not ask again, so Snitt's own alert is the only way the user finds out")
    }

    @Test("Pre-explain accepted and grant available persists enabled = true")
    func grantedTurnOnPersists() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let applied = EventLoggingToggle.apply(true, defaults: defaults,
                                                preExplain: { _ in true },
                                                hasRequested: { false },
                                                markRequested: {},
                                                ensureGranted: { true },
                                                showAlreadyDenied: {})

        #expect(applied == true)
        #expect(EventLoggingSettings.load(defaults).enabled == true)
    }

    /// Turning OFF never consults the ladder — only turning ON needs a
    /// grant, and a mutant that ran `preExplain`/`ensureGranted` on every
    /// call would still pass unless it also refused a same-process false
    /// grant here, so this pins the "off always succeeds" branch directly.
    @Test("Turning off always persists, without consulting the ladder")
    func turningOffNeverConsultsLadder() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        EventLoggingSettings(enabled: true).save(to: defaults)

        var ladderConsulted = false
        let applied = EventLoggingToggle.apply(false, defaults: defaults,
                                                preExplain: { _ in ladderConsulted = true; return true },
                                                ensureGranted: { ladderConsulted = true; return true },
                                                showAlreadyDenied: {})

        #expect(applied == false)
        #expect(ladderConsulted == false)
        #expect(EventLoggingSettings.load(defaults).enabled == false)
    }


    /// F7 (whole-branch review): with the Settings window left open, a
    /// status-item toggle changes the shared store without changing this
    /// window's checkbox — and the window's handlers derive the value they
    /// write from `sender.state`, not from the store. So the next click on
    /// that stale checkbox writes a value computed from the stale visual
    /// state, silently reverting what the user just did from the menu.
    ///
    /// Both halves are asserted, in that order: the checkbox catches up, and
    /// a click after catching up writes the value the user actually sees.
    /// A wrong implementation that refreshed only on construction, or that
    /// refreshed the display without the handlers ever seeing it, fails one
    /// of the two.
    @Test("A settings change made elsewhere shows up when the window becomes key")
    func windowRefreshesFromTheStoreWhenItBecomesKey() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }

        let updater = UpdaterController(settings: UpdateSettings.load(defaults))
        SettingsWindowController.show(updater: updater, defaults: defaults, activate: false)
        let controller = try #require(SettingsWindowController.shared)
        let checkbox = try #require(
            controller.checkbox(titled: SettingsWindowController.agentRecordingTitle))
        #expect(checkbox.state == .off)

        // The status item's own toggle, which writes the shared store
        // directly and knows nothing about this window.
        var settings = AgentSettings.load(defaults)
        settings.agentRecordingEnabled = true
        settings.save(to: defaults)

        controller.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: controller.window))
        #expect(checkbox.state == .on, "the window must show the value the store actually holds")

        // And a click from here turns it OFF, rather than writing `true`
        // again off a stale unchecked box.
        checkbox.performClick(nil)
        #expect(AgentSettings.load(defaults).agentRecordingEnabled == false)
    }
}

/// Unit tests for the microphone's §4.10 ladder — mirrors
/// `EventLoggingToggleTests` exactly, since `MicrophoneToggle.apply` and
/// `EventLoggingToggle.apply` now share the same `PermissionLadder`
/// mechanics and differ only in which service and settings type they name.
@Suite(.serialized)
@MainActor
struct MicrophoneToggleTests {
    init() { _ = NSApplication.shared }

    private func fixtureDefaults() throws -> (UserDefaults, String) {
        let suiteName = "com.snitt.test.mictoggle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    /// Verified to fail against the bug this whole ladder exists to prevent:
    /// an `apply` body that skips straight to `MicrophoneSettings(enabled:
    /// enabled).save(to: defaults)` without consulting `preExplain` makes
    /// the second `#expect` fail — `enabled` reads back `true` even though
    /// `preExplain` here declines.
    @Test("Declining the pre-explain persists nothing and returns false")
    func decliningPreExplainPersistsNothing() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let applied = MicrophoneToggle.apply(true, defaults: defaults,
                                              preExplain: { _ in false },
                                              ensureGranted: { true },
                                              showAlreadyDenied: {})

        #expect(applied == false)
        #expect(MicrophoneSettings.load(defaults).enabled == false)
    }

    /// A first-time refusal must stay silent — `MicrophoneAccess.ensureGranted()`
    /// fires the request and returns `false` immediately, before the user has
    /// answered (see its own doc comment), so raising Snitt's own
    /// "already denied" alert here would contradict a dialog that has not
    /// even been answered yet.
    @Test("A first-time refused grant persists nothing, returns false, and stays silent")
    func firstRefusedGrantStaysSilent() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var showedAlreadyDenied = false
        var markedRequested = false
        let applied = MicrophoneToggle.apply(true, defaults: defaults,
                                              preExplain: { _ in true },
                                              hasRequested: { false },
                                              markRequested: { markedRequested = true },
                                              ensureGranted: { false },
                                              showAlreadyDenied: { showedAlreadyDenied = true })

        #expect(applied == false)
        #expect(MicrophoneSettings.load(defaults).enabled == false)
        #expect(markedRequested, "the first ask must be recorded so a LATER refusal can be told apart")
        #expect(!showedAlreadyDenied,
                "the first ask must not contradict whatever the user is currently deciding")
    }

    /// The other half of the same distinction: once Snitt has already asked
    /// before (`hasRequested` reporting `true`), the only way the user learns
    /// anything is Snitt's own alert.
    @Test("A refusal after an earlier ask persists nothing, returns false, and shows the already-denied alert")
    func repeatRefusedGrantShowsAlreadyDenied() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var showedAlreadyDenied = false
        let applied = MicrophoneToggle.apply(true, defaults: defaults,
                                              preExplain: { _ in true },
                                              hasRequested: { true },
                                              markRequested: {},
                                              ensureGranted: { false },
                                              showAlreadyDenied: { showedAlreadyDenied = true })

        #expect(applied == false)
        #expect(MicrophoneSettings.load(defaults).enabled == false)
        #expect(showedAlreadyDenied,
                "macOS will not raise the dialog again, so Snitt's own alert is the only way the user finds out")
    }

    @Test("Pre-explain accepted and grant available persists enabled = true")
    func grantedTurnOnPersists() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let applied = MicrophoneToggle.apply(true, defaults: defaults,
                                              preExplain: { _ in true },
                                              hasRequested: { false },
                                              markRequested: {},
                                              ensureGranted: { true },
                                              showAlreadyDenied: {})

        #expect(applied == true)
        #expect(MicrophoneSettings.load(defaults).enabled == true)
    }

    /// Turning OFF never consults the ladder — only turning ON needs a
    /// grant.
    @Test("Turning off always persists, without consulting the ladder")
    func turningOffNeverConsultsLadder() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        MicrophoneSettings(enabled: true).save(to: defaults)

        var ladderConsulted = false
        let applied = MicrophoneToggle.apply(false, defaults: defaults,
                                              preExplain: { _ in ladderConsulted = true; return true },
                                              ensureGranted: { ladderConsulted = true; return true },
                                              showAlreadyDenied: {})

        #expect(applied == false)
        #expect(ladderConsulted == false)
        #expect(MicrophoneSettings.load(defaults).enabled == false)
    }
}

// The explaining rows (rev 5, W6).
//
// Rev 4 opened by criticising this window — seven controls with bare labels,
// several of which cannot be understood from a label — and then never fixed
// it, because it was not one of the nine build items. These pin the fix at
// the level that matters: not "there is a subtitle" but "the sentence exists,
// says the thing it has to say, and is reachable without eyes."
@Suite(.serialized)
@MainActor
struct SettingsRowTests {

    init() { _ = NSApplication.shared }

    @Test("Every setting carries an explanation, not just a label")
    func everySettingExplainsItself() {
        for (name, detail) in [
            ("agent recording", SettingsWindowController.agentRecordingDetail),
            ("event logging", SettingsWindowController.eventLoggingDetail),
            ("microphone", SettingsWindowController.microphoneDetail),
            ("automatic updates", SettingsWindowController.automaticUpdatesDetail),
            ("crash reports", SettingsWindowController.crashReportsDetail),
        ] {
            #expect(detail.count > 40, "\(name)'s explanation is \(detail.count) characters")
            #expect(detail.hasSuffix("."), "\(name)'s explanation is not a sentence")
        }
    }

    @Test("The agent-recording row states the disclosure, in as many words")
    func agentRecordingRowDisclosesDisclosure() {
        // The consent-relevant one, pinned specifically. §5 requires every
        // agent-initiated recording to be disclosed and logged; this row is
        // where the person granting the permission is told so. A test that
        // only asserted "there is some explanation" would pass on a sentence
        // that had quietly dropped it.
        let detail = SettingsWindowController.agentRecordingDetail
        #expect(detail.contains("disclosed"), "the disclosure sentence lost 'disclosed'")
        #expect(detail.contains("logged"), "the disclosure sentence lost 'logged'")
    }

    @Test("The explanation reaches VoiceOver, not only the eye")
    func explanationIsAccessible() throws {
        // Through the REAL window rather than a hand-built row: the thing
        // worth pinning is that the window a user opens carries the help, not
        // that a helper function can produce one.
        //
        // A subtitle that exists only as pixels is invisible to the users who
        // most need it explained — and for the agent-recording row that would
        // mean the disclosure is not disclosed.
        let suiteName = "com.snitt.test.settingsrow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        SettingsWindowController.show(updater: UpdaterController(settings: UpdateSettings.load(defaults)),
                                      defaults: defaults, activate: false)
        let checkbox = try #require(
            SettingsWindowController.shared?.checkbox(titled: SettingsWindowController.agentRecordingTitle))
        #expect(checkbox.accessibilityHelp() == SettingsWindowController.agentRecordingDetail,
                "the checkbox carries no accessibility help")
    }

    @Test("The window is wide enough for a sentence")
    func windowIsWideEnoughToRead() {
        // 420pt predated the explanations and would have wrapped each of them
        // into a column of two-word lines.
        #expect(SettingsWindowController.contentWidth >= 520)
    }

    @Test("The window is the height of its rows, with no slack to stretch one")
    func windowFitsItsContent() throws {
        // The defect this pins, reported from the app: the window was a fixed
        // 620pt while its rows needed 485, and `NSStackView` handed the spare
        // 135 to the first row it could stretch — so "Allow agent recording"
        // sat alone above a screenful of nothing and everything else bunched
        // at the bottom.
        //
        // Asserting the window against its own content rather than against a
        // number: rows will change, and a test naming a height would have to
        // be edited every time, which is how the 620 got there.
        let suiteName = "com.snitt.test.settingsfit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        SettingsWindowController.show(
            updater: UpdaterController(settings: UpdateSettings.load(defaults)),
            defaults: defaults, activate: false)
        let window = try #require(SettingsWindowController.shared?.window)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let needed = content.fittingSize.height
        #expect(needed > 100, "the content measured \(needed) — it did not lay out")
        #expect(abs(window.contentLayoutRect.height - needed) < 2,
                "the window is \(window.contentLayoutRect.height) for \(needed) of rows, and the difference gets handed to whichever row will take it")
    }

    @Test("Every rule has air on both sides, and more above it than below")
    func rulesAreNotCramped() throws {
        // Reported from the app: "the gaps/spacing is off around divider
        // lines". The group headers and rules were added without their own
        // spacing, so they inherited the stack's 2pt row gap and the rule sat
        // almost touching the heading under it — a line that had fallen over
        // rather than a division.
        //
        // Measured from the laid-out frames, because that is the only thing
        // about appearance this host can check: it renders blank, but it lays
        // out correctly, and the gaps ARE the defect.
        let suiteName = "com.snitt.test.settingsrules.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        SettingsWindowController.show(
            updater: UpdaterController(settings: UpdateSettings.load(defaults)),
            defaults: defaults, activate: false)
        let stack = try #require(
            SettingsWindowController.shared?.window.contentView as? NSStackView)
        stack.layoutSubtreeIfNeeded()

        let rows = stack.arrangedSubviews
        let ruleIndexes = rows.indices.filter { rows[$0] is NSBox }
        // Five groups, four rules: the first heading sits at the top of the
        // window with nothing above it to divide from. Counted rather than
        // assumed, because a `leadingRule` flag defaulting the wrong way is
        // invisible in a screenshot of the middle of the window.
        #expect(ruleIndexes.count == 4, "expected a rule between groups, found \(ruleIndexes.count)")

        for index in ruleIndexes {
            // Top-down: arrangedSubviews[0] is highest, so the gap ABOVE a
            // view is measured against the one before it in the array.
            let above = rows[index - 1].frame.minY - rows[index].frame.maxY
            let below = rows[index].frame.minY - rows[index + 1].frame.maxY
            #expect(above >= 12, "only \(above)pt above a rule — it is crowding the row before it")
            #expect(below >= 12, "only \(below)pt below a rule — it is crowding its own heading")
            // EVEN, which reverses what this asserted before. It required
            // `above > below` on the reasoning that a heading belongs to what
            // follows it; laid out, that meant 18pt above and 8pt below, and
            // the rule visibly sat twice as far from the content above it as
            // from the heading under it. One constant now feeds both sides.
            #expect(abs(above - below) < 0.5,
                    "uneven margins: \(above)pt above the rule, \(below)pt below")
        }

        // And every rule has the SAME margins as every other, not merely
        // symmetric ones. Four dividers each evenly spaced at a different
        // value would satisfy the loop above and still look arbitrary.
        let margins = ruleIndexes.map { rows[$0 - 1].frame.minY - rows[$0].frame.maxY }
        #expect(margins.allSatisfy { abs($0 - margins[0]) < 0.5 },
                "the dividers do not share one margin: \(margins)")
    }

    @Test("The folder setting is named for the only thing it governs")
    func folderCaptionNamesRecordings() {
        // Every other test here reaches this label through the constant, so
        // the constant could say anything at all and they would still pass.
        // This is the one that reads it.
        //
        // It briefly said "Default path", which sounds like the app's one
        // folder for everything and is not: `RecordingCoordinator` is its only
        // consumer. Export deliberately lands beside the bundle it came from,
        // so with this folder unchanged the two coincide — which is exactly
        // what made the broader name look true, and why nothing noticed.
        let caption = SettingsWindowController.outputDirectoryCaption
        #expect(caption.lowercased().contains("recording"),
                "the folder setting no longer says what it governs: \(caption)")
        // And does not claim the things it does NOT govern.
        for overclaim in ["export", "default path", "everything"] {
            #expect(!caption.lowercased().contains(overclaim),
                    "the caption claims \(overclaim), which this setting does not control: \(caption)")
        }
    }

    @Test("Nothing says the default-path caption twice")
    func theSaveGroupSaysItOnce() throws {
        // The group header was added above a row that already carried its own
        // caption, so the window shipped the phrase twice, one line apart.
        let suiteName = "com.snitt.test.settingsdupe.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        SettingsWindowController.show(
            updater: UpdaterController(settings: UpdateSettings.load(defaults)),
            defaults: defaults, activate: false)
        let content = try #require(SettingsWindowController.shared?.window.contentView)
        var labels: [String] = []
        func collect(_ view: NSView) {
            if let field = view as? NSTextField, !(field is NSSecureTextField) {
                labels.append(field.stringValue)
            }
            view.subviews.forEach(collect)
        }
        collect(content)
        let saying = labels.filter {
            $0.contains(SettingsWindowController.outputDirectoryCaption)
        }
        #expect(saying.count == 1, "the window says it \(saying.count) times: \(saying)")
    }
}
