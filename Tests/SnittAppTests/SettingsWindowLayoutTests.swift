// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
@testable import SnittApp

/// The Settings window's ORDER, as one assertion.
///
/// Every existing test here reaches a control by title, which is exactly the
/// shape that cannot see this: `checkbox(titled:)` finds "Allow recording"
/// wherever it is, so six checkboxes in any arrangement — or with every
/// heading deleted — pass all of them. Grouping is the deliverable of this
/// change, so the outline itself is what gets pinned.
///
/// It is deliberately a single expected list rather than a set of "X is above
/// Y" checks. Pairwise assertions are satisfied by orders nobody asked for,
/// and this project's own count of tests asserting a property adjacent to the
/// one that mattered stands at twenty-seven.
@Suite(.serialized)
@MainActor
struct SettingsWindowLayoutTests {
    init() { _ = NSApplication.shared }

    /// The window as a flat outline: `## heading`, then `- row` for each row
    /// under it, in the order they are stacked. Separators are structural and
    /// contribute nothing to read.
    private func outline() throws -> [String] {
        let controller = try #require(SettingsWindowController.shared)
        let stack = try #require(controller.window.contentView as? NSStackView)
        return stack.arrangedSubviews.compactMap { view -> String? in
            if view is NSBox { return nil }
            if let header = view as? NSTextField { return "## \(header.stringValue)" }
            // A row, named by its LEADING view: a checkbox row leads with its
            // checkbox, and every other kind (a hotkey, the path chooser)
            // leads with a label. Reading the leading view rather than "the
            // first NSButton anywhere" is what keeps a hotkey row from being
            // reported as whatever combination is currently recorded into it.
            //
            // Descends through nested stacks, because the path row wraps its
            // contents in one: the first draft stopped at the outer stack,
            // returned nil, and quietly dropped that row from the outline
            // entirely — an assertion about order with one of the rows missing
            // from both sides of it.
            func leadingName(_ view: NSView) -> String? {
                if let button = view as? NSButton { return button.title }
                if let label = view as? NSTextField { return label.stringValue }
                guard let stack = view as? NSStackView,
                      let first = stack.arrangedSubviews.first else { return nil }
                return leadingName(first)
            }
            return leadingName(view).map { "- \($0)" }
        }
    }

    @Test("The window is grouped and ordered exactly as specified")
    func layoutIsAsSpecified() throws {
        let suiteName = "com.snitt.test.layout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }

        SettingsWindowController.show(updater: UpdaterController(settings: UpdateSettings.load(defaults)),
                                      defaults: defaults, activate: false)

        let actual = try outline()
        #expect(actual == [
            // Application-wide, with no "Application" heading over them.
            "## \(SettingsWindowController.outputDirectoryCaption)",
            "- \(OutputDirectorySettings.load(defaults).directory.path)",
            "## \(SettingsWindowController.shortcutsSectionTitle)",
            "- \(HotkeyAction.record.label)",
            "- \(HotkeyAction.marker.label)",
            // Capture before Agent: the two settings that decide what goes
            // into a recording come before the ones about who may start one.
            "## \(SettingsWindowController.captureSectionTitle)",
            "- \(SettingsWindowController.microphoneTitle)",
            "- \(SettingsWindowController.eventLoggingTitle)",
            "## \(SettingsWindowController.agentSectionTitle)",
            "- \(SettingsWindowController.agentRecordingTitle)",
            "- \(SettingsWindowController.unattendedRecordingTitle)",
            "## \(SettingsWindowController.updatesSectionTitle)",
            "- \(SettingsWindowController.automaticUpdatesTitle)",
            "- \(SettingsWindowController.crashReportsTitle)",
        ], "actual outline:\n\(actual.joined(separator: "\n"))")
    }

    @Test("No hairline sits above the first heading")
    func firstGroupHasNoLeadingRule() throws {
        // `addGroup` draws a rule before its heading, which is right between
        // two groups and wrong at the top of a window — there is nothing above
        // it to divide from except the title bar.
        let suiteName = "com.snitt.test.layoutrule.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }

        SettingsWindowController.show(updater: UpdaterController(settings: UpdateSettings.load(defaults)),
                                      defaults: defaults, activate: false)

        let stack = try #require(SettingsWindowController.shared?.window.contentView as? NSStackView)
        #expect(!(stack.arrangedSubviews.first is NSBox),
                "the window opens on a separator")
        // The rules that DO belong are still there — one before each of the
        // four later headings. Without this, deleting every separator passes
        // the assertion above. Their SPACING is
        // `SettingsWindowTests.everyRuleHasAirOnBothSides`, which owns the
        // count too; this only needs them to exist.
        #expect(stack.arrangedSubviews.contains { $0 is NSBox })
    }

    @Test("The two agent rows announce their full names to VoiceOver")
    func agentRowsAreUnambiguousWithoutTheHeading() throws {
        // The cost of shortening the titles. A section header is a visual
        // grouping and nothing else — VoiceOver moving control to control
        // announces "Allow recording", which on the two controls that decide
        // whether software may watch the screen is the disclosure going
        // missing exactly where it matters.
        let suiteName = "com.snitt.test.layouta11y.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }

        SettingsWindowController.show(updater: UpdaterController(settings: UpdateSettings.load(defaults)),
                                      defaults: defaults, activate: false)
        let controller = try #require(SettingsWindowController.shared)

        let agent = try #require(controller.checkbox(titled: SettingsWindowController.agentRecordingTitle))
        #expect(agent.accessibilityLabel() == "Allow agent recording")
        let unattended = try #require(
            controller.checkbox(titled: SettingsWindowController.unattendedRecordingTitle))
        #expect(unattended.accessibilityLabel() == "Allow unattended agent recording")

        // The rows whose titles say what they are keep them — an accessibility
        // label copied onto every row would be a second place for the name to
        // drift out of step with the visible one.
        let microphone = try #require(controller.checkbox(titled: SettingsWindowController.microphoneTitle))
        #expect(microphone.accessibilityLabel() == SettingsWindowController.microphoneTitle)
    }
}
