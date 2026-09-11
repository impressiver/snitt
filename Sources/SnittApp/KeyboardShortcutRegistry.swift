// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit

/// One editor shortcut: what it does, which key reaches it, and where it
/// appears in the menus.
public struct KeyboardShortcut: Equatable, Sendable {
    /// The menu item's title, and the name shown in the shortcuts help.
    public let title: String
    /// The key equivalent. Lower-case letters, or a control character.
    public let key: String
    /// Empty for a BARE key — space, Home, an arrow with no ⌘. `Cut Selection`
    /// already ships one of these; see `AppShell` for why it needs
    /// `NSMenuItemValidation` to stay scoped.
    public let modifiers: NSEvent.ModifierFlags
    /// Which menu it belongs under.
    public let menu: Menu
    public let selector: Selector

    public enum Menu: String, CaseIterable, Sendable {
        case playback = "Playback"
        case edit = "Edit"
    }
}

/// The one list that both installs the shortcuts and documents them (D84).
///
/// The point is not tidiness. A help dialog written by hand beside a menu
/// built by hand is two descriptions of one behaviour, and they drift — the
/// class `ServerInstructionsTests` exists to catch on the agent surface, where
/// the instructions had already drifted from the tools they described. Here it
/// is cheaper to prevent than to detect: **`shortcuts` is the only place a
/// binding is written down**, `installPlaybackMenu` builds menu items from it,
/// and `helpText` renders the same array. A shortcut that is not in the list
/// exists in neither place, and one that is appears in both or in neither.
///
/// Bare keys are deliberate and already precedented. Space is "also a
/// character", which is the trap D84 named — and the answer already ships:
/// `keyEquivalentModifierMask = []` makes the bare key match, and
/// `AppDelegate`'s `NSMenuItemValidation` conformance is what stops it
/// swallowing that key app-wide. This reuses both rather than inventing a
/// third mechanism.
@MainActor
public enum KeyboardShortcutRegistry {

    /// Named once so the menu and its tests cannot disagree about the wording.
    public static let showClicksTitle = "Show Clicks"

    public static let shortcuts: [KeyboardShortcut] = [
        .init(title: "Play / Pause", key: " ", modifiers: [], menu: .playback,
              selector: #selector(AppDelegate.togglePlayback(_:))),
        .init(title: "Back to Start", key: "\u{1}", modifiers: [], menu: .playback,
              selector: #selector(AppDelegate.rewindToStart(_:))),
        .init(title: "Previous Mark", key: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
              modifiers: [.option], menu: .playback,
              selector: #selector(AppDelegate.goToPreviousMark(_:))),
        .init(title: "Next Mark", key: String(UnicodeScalar(NSRightArrowFunctionKey)!),
              modifiers: [.option], menu: .playback,
              selector: #selector(AppDelegate.goToNextMark(_:))),
    ]

    /// Builds the Playback menu from `shortcuts`, so an item cannot exist
    /// without a binding or a binding without an item.
    public static func playbackMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: KeyboardShortcut.Menu.playback.rawValue,
                              action: nil, keyEquivalent: "")
        let menu = NSMenu(title: KeyboardShortcut.Menu.playback.rawValue)
        for shortcut in shortcuts where shortcut.menu == .playback {
            let entry = NSMenuItem(title: shortcut.title,
                                   action: shortcut.selector,
                                   keyEquivalent: shortcut.key)
            entry.keyEquivalentModifierMask = shortcut.modifiers
            menu.addItem(entry)
        }
        // Appended outside the `shortcuts` loop because it is a different kind
        // of thing: a persistent CHECKABLE state, not a key-triggered action.
        // Forcing it into `shortcuts` would mean an entry with no key, which
        // `helpText` would then render as a shortcut with a blank binding.
        menu.addItem(.separator())
        let clicks = NSMenuItem(title: showClicksTitle,
                                action: #selector(AppDelegate.toggleShowClicks(_:)),
                                keyEquivalent: "")
        menu.addItem(clicks)

        item.submenu = menu
        return item
    }

    /// What Help ▸ Keyboard Shortcuts shows — rendered from the same array the
    /// menu was built from, which is the whole reason this type exists.
    public static var helpText: String {
        KeyboardShortcut.Menu.allCases.compactMap { menu -> String? in
            let rows = shortcuts.filter { $0.menu == menu }
            guard !rows.isEmpty else { return nil }
            let body = rows
                .map { "  \(display(of: $0))\t\($0.title)" }
                .joined(separator: "\n")
            return "\(menu.rawValue)\n\(body)"
        }.joined(separator: "\n\n")
    }

    /// The rendered key for a titled shortcut, for tooltips beside the
    /// buttons that do the same thing. Empty if nothing claims that title, so
    /// a renamed shortcut leaves a tooltip short rather than showing a stale
    /// key.
    public static func shortcutDisplay(titled title: String) -> String {
        shortcuts.first { $0.title == title }.map(display) ?? ""
    }

    /// A key rendered the way macOS writes it, so the help reads like the menu
    /// beside it rather than like a source listing.
    public static func display(of shortcut: KeyboardShortcut) -> String {
        var out = ""
        if shortcut.modifiers.contains(.control) { out += "⌃" }
        if shortcut.modifiers.contains(.option) { out += "⌥" }
        if shortcut.modifiers.contains(.shift) { out += "⇧" }
        if shortcut.modifiers.contains(.command) { out += "⌘" }
        return out + keyName(shortcut.key)
    }

    /// Named rather than printed for the keys that have no glyph. A literal
    /// space renders as nothing at all, which is the one binding most worth
    /// documenting.
    static func keyName(_ key: String) -> String {
        switch key {
        case " ": return "Space"
        case "\u{1}": return "Home"
        case "\u{8}", "\u{7f}": return "Delete"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): return "←"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): return "→"
        default: return key.uppercased()
        }
    }
}
