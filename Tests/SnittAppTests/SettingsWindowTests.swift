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
}
