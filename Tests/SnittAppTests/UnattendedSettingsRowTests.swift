// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
@testable import SnittApp
import SnittAutomation

/// D95's Settings row: the words, and the state the checkbox actually shows.
///
/// The words are the deliverable here as much as the mechanism. The whole
/// feature is a promise that a machine will keep recording after its owner
/// walks away, and the one thing that promise cannot survive is a person not
/// knowing it expires — so the renewal period being IN the help text, derived
/// from the constant that enforces it, is a functional requirement rather than
/// polish.
@Suite(.serialized)
@MainActor
struct UnattendedSettingsRowTests {
    init() { _ = NSApplication.shared }

    private func fixtureDefaults() throws -> (UserDefaults, String) {
        let suiteName = "com.snitt.test.unattendedrow.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    private func storeGrant(_ defaults: UserDefaults, confirmedAt: Date?,
                            agent: Bool = true, on: Bool = true) {
        var settings = AgentSettings.load(defaults)
        settings.agentRecordingEnabled = agent
        settings.unattendedRecordingEnabled = on
        settings.unattendedConfirmedAt = confirmedAt
        settings.save(to: defaults)
    }

    // MARK: - The help text

    @Test("The help text states the renewal period, taken from the constant that enforces it")
    func detailNamesTheRenewalPeriod() {
        let detail = SettingsWindowController.unattendedRecordingDetail
        #expect(detail.contains("\(UnattendedRecordingGrant.renewalDays) days"),
                "the help text does not say how often this needs renewing: \(detail)")

        // EVERY number in the sentence must be the renewal period, not just
        // one of them. The first version of this test checked only that the
        // period appeared SOMEWHERE, and a mutant replacing the first of the
        // two interpolations with a literal 99 survived it — the sentence then
        // read "re-confirm about every 99 days … switches itself off after 30
        // days", which is worse than either number alone. Twenty-seven now.
        let numbers = detail.split(whereSeparator: { !$0.isNumber })
        #expect(!numbers.isEmpty)
        for number in numbers {
            #expect(number == "\(UnattendedRecordingGrant.renewalDays)",
                    "the help text names \(number) days somewhere as well: \(detail)")
        }
        // And that it says a PERSON is needed for it — the renewal is not
        // something the app can do while nobody is here, which is the one
        // limit D95 records that no opt-in removes.
        #expect(detail.lowercased().contains("person"),
                "the help text does not say the renewal needs someone present: \(detail)")
    }

    @Test("An active grant's status line counts the days left, singular when it is one")
    func activeStatusCountsDays() {
        #expect(SettingsWindowController.unattendedStatusText(for: .active(daysRemaining: 12))
                    .contains("12 days"))
        // Pluralization is not decoration: "Renew within 1 days" is the tell
        // that a string was assembled rather than written, on the line a
        // person reads the day before it expires.
        let lastDay = SettingsWindowController.unattendedStatusText(for: .active(daysRemaining: 1))
        #expect(lastDay.contains("1 day"))
        #expect(!lastDay.contains("1 days"))
    }

    @Test("A lapsed grant's status line says it is overdue and what to do")
    func lapsedStatusIsActionable() {
        let today = SettingsWindowController.unattendedStatusText(for: .lapsed(daysAgo: 0))
        #expect(today.contains("today"), "day zero must not read as '0 days ago': \(today)")
        let older = SettingsWindowController.unattendedStatusText(for: .lapsed(daysAgo: 9))
        #expect(older.contains("9 days ago"))
        // Both must name the remedy. A status line that says only "lapsed"
        // leaves a person looking at an unchecked box with no idea that
        // checking it again is the renewal.
        for text in [today, older] {
            #expect(text.lowercased().contains("switch it back on"),
                    "the overdue line does not say how to renew: \(text)")
        }
    }

    @Test("An unconfigured grant shows no status line at all")
    func offShowsNothing() {
        #expect(SettingsWindowController.unattendedStatusText(for: .off).isEmpty)
    }

    /// Finds a static text in the window by its content.
    ///
    /// The status line has no title to look up the way `checkbox(titled:)`
    /// does, and it is the one part of this row that lives OUTSIDE the shared
    /// `settingRow` builder — so nothing else would notice if the `as?
    /// NSStackView` cast that attaches it stopped matching and the label
    /// silently never reached the window.
    private func staticText(containing needle: String) -> NSTextField? {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.stringValue.contains(needle) { return field }
            for child in view.subviews { if let hit = find(child) { return hit } }
            return nil
        }
        return SettingsWindowController.shared?.window.contentView.flatMap(find)
    }

    // MARK: - The row

    @Test("A grant that lapsed shows the checkbox UNCHECKED, with the overdue line")
    func lapsedGrantShowsUnchecked() throws {
        // The assertion this file exists for. Reading `unattendedRecordingEnabled`
        // — which is still `true` in the store here — puts a checkmark on a
        // feature that is authorizing nothing, which is exactly the state
        // `EventLoggingToggle`'s history calls the lie. Only a row that asks
        // `unattendedGrant.status` gets this right.
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        storeGrant(defaults, confirmedAt: Date(timeIntervalSinceNow: -60 * 86_400))
        #expect(AgentSettings.load(defaults).unattendedRecordingEnabled == true,
                "fixture is wrong: the stored flag must still be true for this test to mean anything")

        SettingsWindowController.show(updater: UpdaterController(settings: UpdateSettings.load(defaults)),
                                      defaults: defaults, activate: false,
                                      unattendedToggle: { _, _ in true })

        let box = try #require(SettingsWindowController.shared?
            .checkbox(titled: SettingsWindowController.unattendedRecordingTitle))
        #expect(box.state == .off,
                "a lapsed grant showed as checked — the row is reading the flag, not the grant")
    }

    @Test("A grant confirmed today shows the checkbox checked")
    func activeGrantShowsChecked() throws {
        // The other half, so the test above is not satisfied by a row that
        // simply never checks the box.
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        storeGrant(defaults, confirmedAt: Date())

        SettingsWindowController.show(updater: UpdaterController(settings: UpdateSettings.load(defaults)),
                                      defaults: defaults, activate: false,
                                      unattendedToggle: { _, _ in true })

        let box = try #require(SettingsWindowController.shared?
            .checkbox(titled: SettingsWindowController.unattendedRecordingTitle))
        #expect(box.state == .on)
    }

    @Test("The status line is really in the window, and follows the grant")
    func statusLineIsInTheWindow() throws {
        // Everything else about the wording is asserted against the pure
        // `unattendedStatusText`, which would keep passing with the label
        // omitted from the view hierarchy entirely — a perfect sentence
        // nobody can read. This is the test that fails in that case.
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        storeGrant(defaults, confirmedAt: Date(timeIntervalSinceNow: -40 * 86_400))

        SettingsWindowController.show(updater: UpdaterController(settings: UpdateSettings.load(defaults)),
                                      defaults: defaults, activate: false,
                                      unattendedToggle: { _, _ in true })

        #expect(staticText(containing: "Renewal overdue") != nil,
                "the overdue line is not in the window — only the checkbox says anything")

        // And it UPDATES: a stale line saying "overdue" over a freshly renewed
        // grant is the same defect the other direction.
        var renewed = AgentSettings.load(defaults)
        renewed.unattendedConfirmedAt = Date()
        renewed.save(to: defaults)
        SettingsWindowController.shared?.refreshFromStore()

        #expect(staticText(containing: "Renewal overdue") == nil,
                "the overdue line survived a renewal")
        #expect(staticText(containing: "Renew within") != nil)
    }

    @Test("Turning agent recording off withdraws the unattended checkbox in the same window")
    func agentOptInWithdrawsUnattended() throws {
        // §5.3's global opt-in is the parent grant. Leaving this box checked
        // after unchecking its parent would show a permission that
        // `ConsentPolicy` will refuse — two surfaces disagreeing about what
        // the app is allowed to do, which is the defect this window's whole
        // single-store discipline exists to prevent.
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        storeGrant(defaults, confirmedAt: Date())

        SettingsWindowController.show(updater: UpdaterController(settings: UpdateSettings.load(defaults)),
                                      defaults: defaults, activate: false,
                                      unattendedToggle: { _, _ in true })
        let controller = try #require(SettingsWindowController.shared)
        let agentBox = try #require(controller.checkbox(titled: SettingsWindowController.agentRecordingTitle))
        let unattendedBox = try #require(
            controller.checkbox(titled: SettingsWindowController.unattendedRecordingTitle))
        #expect(unattendedBox.state == .on)

        agentBox.performClick(nil)

        #expect(agentBox.state == .off)
        #expect(unattendedBox.state == .off,
                "unattended recording stayed checked after its parent opt-in was turned off")
    }

    @Test("With agent recording off, the sub-option is DISABLED, not merely unchecked")
    func subOptionIsDisabledWithoutItsParent() throws {
        // An enabled-looking checkbox that cannot do anything is a control
        // that lies. Turning this on while agent recording is off would run
        // the whole Screen Recording ladder — pre-explain sheet, TCC prompt,
        // a person deciding — and then authorize nothing, because
        // `unattendedGrant` composes the two flags.
        //
        // Unchecked is NOT enough and is the state the previous version left:
        // `status.isActive` already reads false without the parent, so a test
        // asserting only the checkmark passes against a fully clickable row.
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        storeGrant(defaults, confirmedAt: Date(), agent: false)

        SettingsWindowController.show(updater: UpdaterController(settings: UpdateSettings.load(defaults)),
                                      defaults: defaults, activate: false,
                                      unattendedToggle: { _, _ in true })
        let controller = try #require(SettingsWindowController.shared)
        let box = try #require(controller.checkbox(titled: SettingsWindowController.unattendedRecordingTitle))
        #expect(box.isEnabled == false)

        // And it comes back the moment the parent does — live, in the same
        // window, without a reopen.
        let agentBox = try #require(controller.checkbox(titled: SettingsWindowController.agentRecordingTitle))
        agentBox.performClick(nil)
        #expect(agentBox.state == .on, "fixture: the parent did not turn on")
        #expect(box.isEnabled, "the sub-option stayed disabled after its parent was enabled")
    }

    @Test("Turning the parent off disables the sub-option in the same window")
    func disablingTheParentDisablesTheChild() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        storeGrant(defaults, confirmedAt: Date())

        SettingsWindowController.show(updater: UpdaterController(settings: UpdateSettings.load(defaults)),
                                      defaults: defaults, activate: false,
                                      unattendedToggle: { _, _ in true })
        let controller = try #require(SettingsWindowController.shared)
        let box = try #require(controller.checkbox(titled: SettingsWindowController.unattendedRecordingTitle))
        #expect(box.isEnabled)

        try #require(controller.checkbox(titled: SettingsWindowController.agentRecordingTitle))
            .performClick(nil)

        #expect(box.isEnabled == false)
        #expect(box.state == .off)
    }

    @Test("A refused Screen Recording grant leaves the checkbox off and persists nothing")
    func refusedGrantRevertsTheCheckbox() throws {
        // Same shape as `eventLoggingRevertsWhenGrantRefused`, aimed at the
        // one setting where a checkmark over a missing grant would be believed
        // by somebody leaving the building.
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        var settings = AgentSettings.load(defaults)
        settings.agentRecordingEnabled = true
        settings.save(to: defaults)

        SettingsWindowController.show(updater: UpdaterController(settings: UpdateSettings.load(defaults)),
                                      defaults: defaults, activate: false,
                                      unattendedToggle: { _, _ in false })

        let box = try #require(SettingsWindowController.shared?
            .checkbox(titled: SettingsWindowController.unattendedRecordingTitle))
        box.performClick(nil)

        #expect(box.state == .off,
                "a refused grant must leave the box unchecked, not showing the click that was refused")
        #expect(AgentSettings.load(defaults).unattendedGrant.status(now: Date()) == .off)
    }

    @Test("The window routes the click through the ladder rather than writing the store itself")
    func clickGoesThroughTheLadder() throws {
        // Verified against the mutant it exists for: a handler that does
        // `settings.unattendedRecordingEnabled = sender.state == .on;
        // settings.save()` satisfies every other assertion in this file and
        // never confirms the Screen Recording permission — which is the entire
        // feature. This is the only test that can see the difference.
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        var settings = AgentSettings.load(defaults)
        settings.agentRecordingEnabled = true
        settings.save(to: defaults)

        var ladderRan = false
        SettingsWindowController.show(updater: UpdaterController(settings: UpdateSettings.load(defaults)),
                                      defaults: defaults, activate: false,
                                      unattendedToggle: { on, store in
                                          ladderRan = true
                                          var s = AgentSettings.load(store)
                                          s.unattendedRecordingEnabled = on
                                          s.unattendedConfirmedAt = on ? Date() : nil
                                          s.save(to: store)
                                          return on
                                      })

        try #require(SettingsWindowController.shared?
            .checkbox(titled: SettingsWindowController.unattendedRecordingTitle)).performClick(nil)

        #expect(ladderRan, "the checkbox wrote the setting directly, skipping the permission ladder")
    }
}
