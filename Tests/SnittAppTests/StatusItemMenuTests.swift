// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp

/// The menu-bar accessory's context menu, as a structure.
///
/// It had no tests: the menu was built inside the code that PRESENTS it, which
/// needs a live `NSStatusItem`, so nothing could reach it. Two changes went
/// through unnoticed as a result — crash reporting was removed from this menu,
/// and the separator before Check for Updates… went with it, leaving the
/// capture toggles running straight into the update actions.
///
/// **Nothing here creates a real status item.** `NSStatusBar.system` is
/// process-global and a test that made one has already cost this suite an
/// unattributed failure; `contextMenu()` needs none of it.
@MainActor
struct StatusItemMenuTests {

    /// An isolated domain — the menu reads the real store, so against
    /// `.standard` these checkmarks would depend on whatever the developer
    /// running the suite happens to have switched on.
    private func fixture() throws -> (UserDefaults, String) {
        let name = "com.snitt.test.statusmenu.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    /// Holds the controller alive for the duration of the check.
    ///
    /// `NSMenuItem.target` is a WEAK, zeroing reference, so
    /// `StatusItemController().contextMenu()` returns a menu whose every
    /// target is already nil — the controller died at the end of the
    /// expression. The first version of `actionableItemsHaveTargets` did
    /// exactly that and failed against correct code, which is worth keeping
    /// visible: a menu built from a temporary controller is inert, and that is
    /// a property of AppKit rather than a quirk of this test.
    private func withMenu<T>(defaults: UserDefaults = .standard,
                             _ body: (NSMenu) -> T) -> T {
        let controller = StatusItemController(defaults: defaults)
        let result = body(controller.contextMenu())
        withExtendedLifetime(controller) {}
        return result
    }

    /// Titles only, separators marked — the shape a person sees.
    private func shape() -> [String] {
        withMenu { $0.items.map { $0.isSeparatorItem ? "---" : $0.title } }
    }

    @Test("A separator divides the capture toggles from the update actions")
    func separatorBeforeUpdates() throws {
        // The reported defect. Asserted as ADJACENCY rather than "a separator
        // exists somewhere" — this menu already had two separators before this
        // one was added, so a count or an any-match passes against a menu with
        // the divider in entirely the wrong place.
        let items = shape()
        let voiceover = try #require(items.firstIndex(of: SettingsWindowController.microphoneTitle))
        let updates = try #require(items.firstIndex(of: "Check for Updates…"))
        #expect(voiceover < updates)
        #expect(items[voiceover..<updates].contains("---"),
                "nothing separates the capture toggles from the update actions: \(items)")
    }

    @Test("The separator sits directly before Check for Updates…")
    func separatorIsAdjacentToUpdates() throws {
        // Tighter than the test above, and the reason is the bleed warning: it
        // appears between the two only when a speaker route is live, so a
        // divider placed above it would satisfy "something separates them"
        // while visually detaching the warning from the microphone toggle it
        // is about.
        let items = shape()
        let updates = try #require(items.firstIndex(of: "Check for Updates…"))
        #expect(updates > 0)
        #expect(items[updates - 1] == "---",
                "the divider is not immediately above Check for Updates…: \(items)")
    }

    @Test("Crash reporting is gone from this menu")
    func crashReportingIsNotHere() {
        // It lives in Settings now, with the detail text this menu had nowhere
        // to put. Pinned so it cannot drift back and give one setting two
        // controls that can disagree.
        #expect(!shape().contains(SettingsWindowController.crashReportsTitle))
    }

    @Test("The fast path still carries everything it is for")
    func theMenuStillDoesItsJob() {
        // Removing an item is one keystroke away from removing its neighbour.
        // §4.11 makes this menu the fast path, so what it must still offer is
        // worth stating rather than leaving to whoever reads the diff.
        let items = shape()
        for expected in [SettingsWindowController.agentRecordingAccessibilityLabel, SettingsWindowController.eventLoggingTitle, SettingsWindowController.microphoneTitle,
                         "Check for Updates…", "Automatically check for updates",
                         "Quit Snitt"] {
            #expect(items.contains(expected), "the menu lost \(expected)")
        }
    }

    @Test("The menu takes its titles from the window, so one setting has one name")
    func menuNamesMatchTheWindow() {
        // Two surfaces over one `UserDefaults` key is the discipline this menu
        // and the Settings window were built on; two NAMES over one key is the
        // same defect worn differently — somebody turns off "Record voiceover"
        // here and goes looking for it as "Record microphone" there.
        //
        // The agent items are the deliberate exception and are asserted as
        // such rather than skipped: the window shortened those titles because
        // a section header now supplies the noun, and this menu has no
        // headers, so it shows the fully-qualified spelling.
        let items = shape()
        #expect(!items.contains("Record voiceover"), "the menu kept the old name")
        #expect(!items.contains("Log input events"), "the menu kept the old name")
        #expect(!items.contains(SettingsWindowController.agentRecordingTitle),
                "\"Allow recording\" alone says nothing in a menu with no Agent heading")
    }

    @Test("Every actionable item can actually be picked")
    func actionableItemsHaveTargets() {
        // An item with no target is disabled and does nothing when clicked,
        // which looks like a broken app rather than a missing wire — and is
        // exactly what a hand-built menu gets wrong. The bleed warning is the
        // one deliberate exception: it is informational and disabled on
        // purpose, so it is identified by that rather than skipped by title.
        withMenu { menu in
            for item in menu.items where !item.isSeparatorItem {
                guard item.action != nil else {
                    #expect(item.isEnabled == false,
                            "\(item.title) has no action but is still enabled")
                    continue
                }
                #expect(item.target != nil, "\(item.title) has an action with no target")
            }
        }
    }
}

/// The checkmarks, which are read from the store as the menu is built.
///
/// These four settings appear both here and in the Settings window — by
/// design, since this menu is §4.11's fast path. What used to differ was the
/// ANSWER: each surface cached its own, and a change in one left the other
/// stale until a sync patch caught it. The menu is rebuilt on every
/// right-click, so reading live removes the whole class.
@MainActor
struct StatusItemMenuStateTests {

    private func fixture() throws -> (UserDefaults, String) {
        let name = "com.snitt.test.statusmenustate.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    private func state(of title: String, in defaults: UserDefaults) -> NSControl.StateValue? {
        let controller = StatusItemController(defaults: defaults)
        let menu = controller.contextMenu()
        let value = menu.items.first { $0.title == title }?.state
        withExtendedLifetime(controller) {}
        return value
    }

    @Test("Each checkmark reflects what is stored, not a default")
    func checkmarksReadTheStore() throws {
        let (defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }

        // All four ON, so a menu that ignored the store and showed everything
        // off fails on every one. The off case is covered below — asserting
        // only one polarity passes against a checkmark hardcoded to it.
        var agent = AgentSettings.load(defaults)
        agent.agentRecordingEnabled = true
        agent.save(to: defaults)
        EventLoggingSettings(enabled: true).save(to: defaults)
        MicrophoneSettings(enabled: true).save(to: defaults)
        var updates = UpdateSettings.load(defaults)
        updates.automaticChecksEnabled = true
        updates.save(to: defaults)

        #expect(state(of: SettingsWindowController.agentRecordingAccessibilityLabel, in: defaults) == .on)
        #expect(state(of: SettingsWindowController.eventLoggingTitle, in: defaults) == .on)
        #expect(state(of: SettingsWindowController.microphoneTitle, in: defaults) == .on)
        #expect(state(of: "Automatically check for updates", in: defaults) == .on)
    }

    @Test("A store written AFTER the controller exists still shows through")
    func laterWritesAreVisible() throws {
        // THE property the sweep bought, and the one a mirror cannot have:
        // the Settings window writing this key while the app is running must
        // change what the menu shows, with nothing told to refresh. Against
        // the old cached mirrors this failed — the value was captured at
        // launch and only `refreshStatusItemFromSettings` moved it.
        let (defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }

        let controller = StatusItemController(defaults: defaults)
        #expect(controller.contextMenu().items
            .first { $0.title == SettingsWindowController.microphoneTitle }?.state == .off)

        MicrophoneSettings(enabled: true).save(to: defaults)

        #expect(controller.contextMenu().items
            .first { $0.title == SettingsWindowController.microphoneTitle }?.state == .on,
                "the menu showed stale state after the store changed")
        withExtendedLifetime(controller) {}
    }
}
