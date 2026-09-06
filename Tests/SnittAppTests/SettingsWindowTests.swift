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
        #expect(EventLoggingSettings.load(defaults).enabled == false)
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
