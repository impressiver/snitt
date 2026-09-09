// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import Carbon.HIToolbox
import Foundation

/// Which hotkey a `HotkeyCombination` controls (D55). Snitt has exactly
/// two: start/stop recording, and drop a marker.
public enum HotkeyAction: CaseIterable, Sendable {
    case record
    case marker

    /// Human-readable name for the Settings window's recorder button and
    /// for a registration-failure alert.
    var label: String {
        switch self {
        case .record: return "Record hotkey"
        case .marker: return "Marker hotkey"
        }
    }
}

/// Persisted per-action hotkey combinations (D55).
///
/// A combination that has never been customized reads back as today's
/// shipped default — `.defaultCombination` (⌥⌘5) for `record`,
/// `.markerCombination` (⌥⌘M) for `marker` — so an existing user's hotkeys
/// do not change out from under them the moment this ships. `keyCode` and
/// `modifiers` are stored as two SEPARATE `UserDefaults` keys rather than
/// one encoded blob: `UserDefaults.object(forKey:)` returning `nil` (as
/// opposed to `integer(forKey:)`'s coercion of "absent" to `0`) is what lets
/// `load` tell "never written" apart from "written as zero", the same
/// absent-vs-invalid discipline every other settings type in this file
/// group already applies — a stored `keyCode == 0` is a real (if unusual)
/// recorded key and must not be confused with "nothing was ever stored
/// here". Both keys of a pair are required together; either one missing
/// falls back to that action's default in full, rather than pairing a
/// stored keyCode with a defaulted modifiers (or vice versa), which could
/// silently reassemble a combination nobody ever actually recorded.
public struct HotkeySettings: Sendable, Equatable {
    public var recordCombination: HotkeyCombination
    public var markerCombination: HotkeyCombination

    private static let recordKeyCodeKey = "com.impressiver.snitt.hotkey.record.keyCode"
    private static let recordModifiersKey = "com.impressiver.snitt.hotkey.record.modifiers"
    private static let markerKeyCodeKey = "com.impressiver.snitt.hotkey.marker.keyCode"
    private static let markerModifiersKey = "com.impressiver.snitt.hotkey.marker.modifiers"

    public init(recordCombination: HotkeyCombination = .defaultCombination,
                markerCombination: HotkeyCombination = .markerCombination) {
        self.recordCombination = recordCombination
        self.markerCombination = markerCombination
    }

    public subscript(action: HotkeyAction) -> HotkeyCombination {
        get {
            switch action {
            case .record: return recordCombination
            case .marker: return markerCombination
            }
        }
        set {
            switch action {
            case .record: recordCombination = newValue
            case .marker: markerCombination = newValue
            }
        }
    }

    public static func load(_ defaults: UserDefaults = .standard) -> HotkeySettings {
        HotkeySettings(
            recordCombination: readCombination(defaults, keyCodeKey: recordKeyCodeKey,
                                               modifiersKey: recordModifiersKey,
                                               fallback: .defaultCombination),
            markerCombination: readCombination(defaults, keyCodeKey: markerKeyCodeKey,
                                               modifiersKey: markerModifiersKey,
                                               fallback: .markerCombination))
    }

    public func save(to defaults: UserDefaults = .standard) {
        Self.writeCombination(recordCombination, to: defaults,
                              keyCodeKey: Self.recordKeyCodeKey, modifiersKey: Self.recordModifiersKey)
        Self.writeCombination(markerCombination, to: defaults,
                              keyCodeKey: Self.markerKeyCodeKey, modifiersKey: Self.markerModifiersKey)
    }

    private static func readCombination(_ defaults: UserDefaults, keyCodeKey: String,
                                        modifiersKey: String,
                                        fallback: HotkeyCombination) -> HotkeyCombination {
        guard let keyCode = defaults.object(forKey: keyCodeKey) as? Int,
              let modifiers = defaults.object(forKey: modifiersKey) as? Int else {
            return fallback
        }
        return HotkeyCombination(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }

    private static func writeCombination(_ combination: HotkeyCombination, to defaults: UserDefaults,
                                         keyCodeKey: String, modifiersKey: String) {
        defaults.set(Int(combination.keyCode), forKey: keyCodeKey)
        defaults.set(Int(combination.modifiers), forKey: modifiersKey)
    }
}

/// Owns the app's two REAL hotkey registrations and is the single place
/// that changes them (D55).
///
/// Persistence (`HotkeySettings`) and the live OS-level registration
/// (`HotkeyMonitor`) must move together — a setting that reads back
/// correctly but nothing acts on is M5b's R22 defect (the automatic-updates
/// checkbox that never told Sparkle) in a new place. `apply(_:to:)` below is
/// written so that can't happen structurally: it persists a new combination
/// ONLY after confirming a `HotkeyMonitor` for it actually started.
@MainActor
public final class HotkeyRegistrar {
    private var monitors: [HotkeyAction: HotkeyMonitor] = [:]
    private let handlers: [HotkeyAction: () -> Void]

    public init(onRecord: @escaping () -> Void, onMarker: @escaping () -> Void) {
        handlers = [.record: onRecord, .marker: onMarker]
    }

    /// Registers both hotkeys from `defaults` (today's ⌥⌘5 / ⌥⌘M for a user
    /// who has never customized either — see `HotkeySettings.load`). Called
    /// once at launch.
    ///
    /// A combination another app already owns is reported through
    /// `reportFailure` — production wires this to the same alert
    /// `main.swift` always raised for exactly this failure — and that
    /// action is simply left unregistered rather than retried; the menu bar
    /// remains usable either way (§5.3's kill switch does not depend on
    /// either hotkey).
    public func start(defaults: UserDefaults = .standard,
                      reportFailure: @MainActor (HotkeyAction, HotkeyCombination) -> Void) {
        let settings = HotkeySettings.load(defaults)
        for action in HotkeyAction.allCases {
            register(action, combination: settings[action], reportFailure: reportFailure)
        }
    }

    /// Re-registers ONE action with a new combination, persisting it to
    /// `defaults` only once the new combination is confirmed to have
    /// actually started (D55; see this type's own doc comment on why that
    /// ordering is the whole point). Returns whether it succeeded, so a
    /// caller (the Settings window's key recorder) can revert its own
    /// display without needing to re-derive success from the store.
    ///
    /// A no-op — returns `true` without touching the OS registration or the
    /// store — when `combination` is already the one currently registered
    /// for `action`. Purely an optimization (stopping and immediately
    /// restarting the identical combination would still succeed, since the
    /// OS slot is freed before the new registration is attempted): it just
    /// avoids the needless churn of tearing down and recreating a
    /// `HotkeyMonitor`, and the redundant `UserDefaults` write, for a
    /// change that changes nothing.
    ///
    /// Otherwise stops the OLD monitor for this action before starting the
    /// new one. If the NEW registration then fails (another app owns it,
    /// or — for a marker/record swap — Snitt's OTHER hotkey does), the old
    /// combination is restarted rather than left dead, so the action still
    /// has a working hotkey after a rejected change instead of none at all.
    @discardableResult
    public func apply(_ combination: HotkeyCombination, to action: HotkeyAction,
                      defaults: UserDefaults = .standard,
                      reportFailure: @MainActor (HotkeyAction, HotkeyCombination) -> Void = { _, _ in }) -> Bool {
        if self.combination(for: action) == combination { return true }

        let previous = monitors[action]
        previous?.stop()

        let onFire = handlers[action] ?? {}
        let monitor = HotkeyMonitor(combination: combination, onFire: onFire)
        do {
            try monitor.start()
        } catch {
            // Restore the old combination so the action is not left with NO
            // hotkey after a rejected change. `try?`, not `try`: if the
            // restart fails too, the combination is unavailable for some
            // OTHER reason, and there is nothing left to fall back to but
            // the menu bar anyway — the same place a failed initial
            // registration already leaves things.
            if let previous { try? previous.start() }
            reportFailure(action, combination)
            return false
        }
        monitors[action] = monitor

        var settings = HotkeySettings.load(defaults)
        settings[action] = combination
        settings.save(to: defaults)
        return true
    }

    /// The combination CURRENTLY registered for `action`, or `nil` if
    /// nothing is live (registration failed and was never retried).
    ///
    /// Reads the real `HotkeyMonitor`'s own stored combination, not
    /// `HotkeySettings`' — this is the difference between "the setting
    /// changed" and "the setting changed AND was actually re-registered",
    /// which is the exact distinction this task's test must draw (see
    /// `HotkeySettingsTests`).
    public func combination(for action: HotkeyAction) -> HotkeyCombination? {
        monitors[action]?.combination
    }

    public func isRegistered(_ action: HotkeyAction) -> Bool {
        monitors[action]?.isRegistered ?? false
    }

    private func register(_ action: HotkeyAction, combination: HotkeyCombination,
                          reportFailure: @MainActor (HotkeyAction, HotkeyCombination) -> Void) {
        let onFire = handlers[action] ?? {}
        let monitor = HotkeyMonitor(combination: combination, onFire: onFire)
        do {
            try monitor.start()
            monitors[action] = monitor
        } catch {
            reportFailure(action, combination)
        }
    }
}

extension HotkeyCombination {
    /// Builds a combination from a key event captured by the Settings
    /// window's recorder control (D55). `NSEvent.keyCode` reports the SAME
    /// HIToolbox virtual keycode `HotkeyCombination.defaultCombination`
    /// already uses (`kVK_ANSI_5` etc.) — only the modifier flags need
    /// translating, since AppKit and Carbon represent them with different
    /// bit layouts.
    init(fromKeyEvent event: NSEvent) {
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    /// A human-readable rendering ("⌥⌘M") for the Settings window's
    /// recorder button and for a registration-failure alert naming the
    /// combination that failed. Modifier order matches macOS's own
    /// convention (control, option, shift, command).
    var displayString: String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols + Self.keyName(for: keyCode)
    }

    /// Covers every key `defaultCombination`/`markerCombination` use today
    /// and every other key most people would actually record — letters,
    /// digits, and a handful of named keys. An uncommon key (a function key,
    /// an arrow) falls back to `Key <code>` rather than crashing or lying
    /// with the wrong glyph.
    private static let keyNames: [UInt32: String] = [
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
        UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
        UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
        UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
        UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
        UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
        UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
        UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
        UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
        UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return",
        UInt32(kVK_Tab): "Tab", UInt32(kVK_Delete): "Delete",
        UInt32(kVK_Escape): "Escape",
    ]

    private static func keyName(for keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }
}
