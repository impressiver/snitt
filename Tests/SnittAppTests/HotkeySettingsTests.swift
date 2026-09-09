// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Carbon.HIToolbox
import Foundation
@testable import SnittApp

private func fixtureDefaults() throws -> (UserDefaults, String) {
    let suiteName = "com.snitt.test.hotkeys.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    return (defaults, suiteName)
}

private func keyEvent(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                     timestamp: 0, windowNumber: 0, context: nil,
                     characters: "", charactersIgnoringModifiers: "",
                     isARepeat: false, keyCode: UInt16(keyCode))!
}

// MARK: - HotkeySettings persistence (pure — no real hotkey registration)

@Suite
struct HotkeySettingsPersistenceTests {
    @Test("A never-written store reads back today's shipped combinations")
    func defaultsMatchTodaysShippedCombinations() throws {
        // D55: an existing user's hotkeys must not change out from under
        // them the moment this ships. Verified to fail against a plausible
        // wrong default (e.g. a zeroed `HotkeyCombination(keyCode: 0,
        // modifiers: 0)`), which would also silently hijack the "a" key
        // with no modifier.
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = HotkeySettings.load(defaults)
        #expect(settings.recordCombination == .defaultCombination)
        #expect(settings.markerCombination == .markerCombination)
    }

    @Test("A saved combination round-trips exactly")
    func roundTripsCustomCombinations() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let record = HotkeyCombination(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(optionKey | controlKey))
        let marker = HotkeyCombination(keyCode: UInt32(kVK_ANSI_8), modifiers: UInt32(shiftKey | controlKey))
        HotkeySettings(recordCombination: record, markerCombination: marker).save(to: defaults)

        let loaded = HotkeySettings.load(defaults)
        #expect(loaded.recordCombination == record)
        #expect(loaded.markerCombination == marker)
    }

    @Test("A half-written pair falls back to the FULL default, not a mismatched keyCode/modifiers")
    func aPartiallyWrittenPairFallsBackToTheFullDefault() throws {
        // Mirrors this project's repeated absent-vs-invalid lesson
        // (`CrashReportSettings`'s own doc comment lists four prior
        // instances): a wrong implementation that reads `keyCode` and
        // `modifiers` independently, each falling back to ITS OWN half of
        // `.defaultCombination`, could reassemble a combination nobody
        // ever actually recorded — e.g. a stray `modifiers` key surviving
        // from an older build's format alongside a freshly-written
        // `keyCode`. Only `keyCode` is written here; `load` must ignore it
        // entirely and return the full default, not `(thisKeyCode,
        // defaultCombination.modifiers)`.
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Int(kVK_ANSI_9), forKey: "com.impressiver.snitt.hotkey.record.keyCode")

        #expect(HotkeySettings.load(defaults).recordCombination == .defaultCombination)
    }

    @Test("The subscript reads and writes the action it was given, not the other one")
    func subscriptAddressesTheCorrectAction() {
        var settings = HotkeySettings()
        let newRecord = HotkeyCombination(keyCode: UInt32(kVK_ANSI_7), modifiers: UInt32(controlKey))
        settings[.record] = newRecord
        #expect(settings[.record] == newRecord)
        #expect(settings[.marker] == .markerCombination, "writing .record must not touch .marker")
    }
}

// MARK: - HotkeyCombination formatting and key-event translation (pure)

struct HotkeyCombinationFormattingTests {
    @Test("displayString renders modifiers in macOS's own order")
    func displayStringOrdersModifiersCorrectly() {
        let combo = HotkeyCombination(keyCode: UInt32(kVK_ANSI_M),
                                      modifiers: UInt32(optionKey | cmdKey))
        #expect(combo.displayString == "⌥⌘M")
    }

    @Test("displayString includes every modifier that is set")
    func displayStringIncludesAllFourModifiers() {
        let combo = HotkeyCombination(keyCode: UInt32(kVK_ANSI_5),
                                      modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        #expect(combo.displayString == "⌃⌥⇧⌘5")
    }

    @Test("A key event's AppKit modifier flags translate to the matching Carbon bits")
    func fromKeyEventTranslatesModifiers() {
        let event = keyEvent(keyCode: UInt32(kVK_ANSI_9), modifiers: [.option, .control])
        let combo = HotkeyCombination(fromKeyEvent: event)

        #expect(combo.keyCode == UInt32(kVK_ANSI_9))
        #expect(combo.modifiers == UInt32(optionKey | controlKey))
        // Discriminates against a mutant that ORs in every modifier
        // unconditionally: shift/command were never pressed, so their bits
        // must be absent.
        #expect(combo.modifiers & UInt32(shiftKey) == 0)
        #expect(combo.modifiers & UInt32(cmdKey) == 0)
    }
}

// MARK: - HotkeyRegistrar and the Settings window's recorder (real OS registration)

/// Every test here registers a REAL combination with the window server via
/// `HotkeyRegistrar`/`HotkeyMonitor`, and several build a real
/// `SettingsWindowController` window (through `activate: false` — see that
/// method's own doc comment). Serialized for the same reason
/// `HotkeyMonitorTests.HotkeyRegistrationTests` and `SettingsWindowTests`
/// already are: real, process-wide, OS-level state and real `NSWindow`
/// construction must not race another test in this same suite. The
/// combinations used throughout are deliberately NOT `.defaultCombination`/
/// `.markerCombination` — those two are exactly what
/// `HotkeyMonitorTests.HotkeyRegistrationTests` (a DIFFERENT, independently
/// serialized suite that swift-testing runs concurrently with this one)
/// already registers for real.
@Suite(.serialized)
@MainActor
struct HotkeyRegistrarTests {
    init() { _ = NSApplication.shared }

    /// The test the dispatch calls out by name: a wrong implementation that
    /// persists the new combination to `HotkeySettings` without actually
    /// re-registering — M5b's R22 defect in a new place — would make the
    /// setting read back correctly while the OLD combination stays the one
    /// actually live. Asserted at the OS level, not just via
    /// `HotkeySettings.load`: a competing monitor for the NEW combination
    /// must fail to register (because THIS registrar already holds it), and
    /// a competing monitor for the OLD combination must succeed (because it
    /// was actually released).
    @Test("apply() re-registers the REAL hotkey, not merely the stored setting")
    func applyReRegistersTheRealHotkeyNotJustTheSetting() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let oldCombo = HotkeyCombination(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(optionKey | controlKey))
        let newCombo = HotkeyCombination(keyCode: UInt32(kVK_ANSI_8), modifiers: UInt32(optionKey | controlKey))

        let registrar = HotkeyRegistrar(onRecord: {}, onMarker: {})
        #expect(registrar.apply(oldCombo, to: .record, defaults: defaults))

        let changed = registrar.apply(newCombo, to: .record, defaults: defaults)
        #expect(changed)
        #expect(HotkeySettings.load(defaults).recordCombination == newCombo,
                "the SETTING must read back as the new combination")
        #expect(registrar.combination(for: .record) == newCombo,
                "the REGISTERED combination — read from the live HotkeyMonitor, not the store — must also be the new one")

        // OS-level proof, independent of this registrar's own bookkeeping:
        // a competing monitor for the OLD combination must now succeed
        // (released), and one for the NEW combination must fail (held).
        let oldIsFree = HotkeyMonitor(combination: oldCombo) {}
        #expect(throws: Never.self) { try oldIsFree.start() }
        oldIsFree.stop()

        let newIsHeld = HotkeyMonitor(combination: newCombo) {}
        #expect(throws: (any Error).self,
                "the new combination must be genuinely registered with the OS by `registrar`, not just recorded in a settings struct") {
            try newIsHeld.start()
        }
    }

    /// D55's "must say so" for the Settings window path, exercised at
    /// `HotkeyRegistrar` directly: a combination another registration
    /// already owns must be refused, must persist nothing, must leave the
    /// PREVIOUS combination live, and must report the failure.
    @Test("apply() refuses a combination another registration already owns, restores the previous one, and persists nothing")
    func applyRefusesAnAlreadyTakenCombinationAndRestoresThePrevious() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownCombo = HotkeyCombination(keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(shiftKey | controlKey))
        let takenCombo = HotkeyCombination(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey | shiftKey))

        // Someone else (a different app, modeled here by a second, unrelated
        // HotkeyMonitor) already owns `takenCombo`.
        let otherApp = HotkeyMonitor(combination: takenCombo) {}
        try otherApp.start()
        defer { otherApp.stop() }

        let registrar = HotkeyRegistrar(onRecord: {}, onMarker: {})
        #expect(registrar.apply(ownCombo, to: .record, defaults: defaults))

        var reportedFailures: [(HotkeyAction, HotkeyCombination)] = []
        let succeeded = registrar.apply(takenCombo, to: .record, defaults: defaults) { action, combination in
            reportedFailures.append((action, combination))
        }

        #expect(succeeded == false)
        #expect(reportedFailures.count == 1)
        #expect(reportedFailures.first?.0 == .record)
        #expect(reportedFailures.first?.1 == takenCombo)
        #expect(HotkeySettings.load(defaults).recordCombination == ownCombo,
                "a refused change must persist nothing")
        #expect(registrar.combination(for: .record) == ownCombo,
                "the action must still have its PREVIOUS hotkey live, not none at all")
        // `combination(for:)` alone is too weak here: it reads a cached
        // reference to whatever `HotkeyMonitor` object the dictionary
        // still holds, which stays `ownCombo` even if that monitor was
        // stopped and never restarted. `isRegistered` plus an OS-level
        // competing-registration probe is what actually proves `ownCombo`
        // is LIVE again, not merely remembered.
        #expect(registrar.isRegistered(.record),
                "the previous hotkey must have been RESTARTED after the rejected change, not just remembered")
        let ownComboIsHeld = HotkeyMonitor(combination: ownCombo) {}
        #expect(throws: (any Error).self,
                "ownCombo must be genuinely re-registered with the OS, not just left as a stale dictionary entry") {
            try ownComboIsHeld.start()
        }
    }

    // MARK: - The Settings window's recorder button, end to end

    @Test("Capturing a key combination in the Settings window re-registers it and updates the button")
    func capturingAKeyReRegistersTheHotkeyAndUpdatesTheButton() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }

        let updater = UpdaterController(settings: UpdateSettings.load(defaults))
        let registrar = HotkeyRegistrar(onRecord: {}, onMarker: {})
        SettingsWindowController.show(updater: updater, defaults: defaults, hotkeyRegistrar: registrar,
                                      activate: false)

        let button = try #require(SettingsWindowController.shared?.hotkeyButton(for: .record))
        let newCombo = HotkeyCombination(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(optionKey | controlKey))
        button.beginRecording()
        button.capture(keyEvent(keyCode: newCombo.keyCode,
                               modifiers: NSEvent.ModifierFlags(carbonModifiers: newCombo.modifiers)))

        #expect(HotkeySettings.load(defaults).recordCombination == newCombo)
        #expect(registrar.combination(for: .record) == newCombo,
                "the button must have driven a REAL re-registration, not just a settings write")
        #expect(button.title.contains(newCombo.displayString))
        #expect(button.isRecording == false)
    }

    @Test("A conflicting capture reverts the button's title and alerts, without persisting")
    func capturingAConflictingKeyRevertsAndAlerts() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }

        let takenCombo = HotkeyCombination(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(optionKey | shiftKey))
        let otherApp = HotkeyMonitor(combination: takenCombo) {}
        try otherApp.start()
        defer { otherApp.stop() }

        let updater = UpdaterController(settings: UpdateSettings.load(defaults))
        let registrar = HotkeyRegistrar(onRecord: {}, onMarker: {})
        var alerted: [(HotkeyAction, HotkeyCombination)] = []
        SettingsWindowController.show(updater: updater, defaults: defaults, hotkeyRegistrar: registrar,
                                      activate: false,
                                      hotkeyConflictAlert: { action, combination in
                                          alerted.append((action, combination))
                                      })

        let button = try #require(SettingsWindowController.shared?.hotkeyButton(for: .marker))
        let beforeTitle = button.title
        button.beginRecording()
        button.capture(keyEvent(keyCode: takenCombo.keyCode,
                               modifiers: NSEvent.ModifierFlags(carbonModifiers: takenCombo.modifiers)))

        #expect(alerted.count == 1)
        #expect(alerted.first?.0 == .marker)
        #expect(alerted.first?.1 == takenCombo)
        #expect(HotkeySettings.load(defaults).markerCombination == .markerCombination,
                "a refused capture must not persist the rejected combination")
        #expect(button.title == beforeTitle,
                "the button must show the UNCHANGED combination, not the one that failed to register")
    }

    @Test("Escape cancels a recording without persisting or reporting a failure")
    func escapeCancelsRecording() throws {
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        let updater = UpdaterController(settings: UpdateSettings.load(defaults))
        let registrar = HotkeyRegistrar(onRecord: {}, onMarker: {})
        var alerted = false
        SettingsWindowController.show(updater: updater, defaults: defaults, hotkeyRegistrar: registrar,
                                      activate: false,
                                      hotkeyConflictAlert: { _, _ in alerted = true })

        let button = try #require(SettingsWindowController.shared?.hotkeyButton(for: .record))
        let beforeTitle = button.title
        button.beginRecording()
        button.capture(keyEvent(keyCode: UInt32(kVK_Escape), modifiers: []))

        #expect(button.isRecording == false)
        #expect(button.title == beforeTitle)
        #expect(alerted == false)
        #expect(HotkeySettings.load(defaults).recordCombination == .defaultCombination,
                "Escape must not have recorded ⎋ itself as the new combination")
    }

    @Test("A bare key with no modifier is ignored, and recording continues")
    func aBareKeyWithNoModifierIsIgnored() throws {
        // A global hotkey with no modifier would hijack ordinary typing —
        // the same reasoning `HotkeyCombination.defaultCombination`'s own
        // doc comment gives for always shipping with one. Verified to fail
        // against a mutant that accepts any keyCode regardless of
        // modifiers: `isRecording` would flip to `false` here instead of
        // staying `true`.
        let (defaults, suiteName) = try fixtureDefaults()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            SettingsWindowController.resetForTesting()
        }
        let updater = UpdaterController(settings: UpdateSettings.load(defaults))
        let registrar = HotkeyRegistrar(onRecord: {}, onMarker: {})
        SettingsWindowController.show(updater: updater, defaults: defaults, hotkeyRegistrar: registrar,
                                      activate: false)

        let button = try #require(SettingsWindowController.shared?.hotkeyButton(for: .record))
        button.beginRecording()
        button.capture(keyEvent(keyCode: UInt32(kVK_ANSI_A), modifiers: []))

        #expect(button.isRecording, "a bare key must not end the recording session")
        #expect(HotkeySettings.load(defaults).recordCombination == .defaultCombination)
    }
}

private extension NSEvent.ModifierFlags {
    /// The inverse of `HotkeyCombination.init(fromKeyEvent:)`'s translation,
    /// for building a synthetic `NSEvent` from a `HotkeyCombination` a test
    /// already has in hand.
    init(carbonModifiers: UInt32) {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        self = flags
    }
}
