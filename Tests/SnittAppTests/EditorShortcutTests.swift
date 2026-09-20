// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp

/// Every editor command's key, and the promise that one place owns it.
///
/// **The failure this exists for is a button that lies.** A toolbar tooltip
/// reading "Export (⌘E)" while the menu registers something else is found out
/// by pressing the key and having nothing happen — and it is the obvious
/// outcome of writing a shortcut twice, once in `NSMenuItem(keyEquivalent:)`
/// and once in a `.help()` string. `EditorCommand` is the one spelling; these
/// are what keep it the one spelling.
@Suite(.serialized)
@MainActor
struct EditorShortcutTests {
    init() { _ = NSApplication.shared }

    /// Every menu item in the app, flattened.
    private func allItems() -> [NSMenuItem] {
        AppShell.buildMainMenu().items.compactMap(\.submenu).flatMap { $0.items }
    }

    @Test("Every command has a menu item registering exactly its key")
    func everyCommandIsRegistered() throws {
        // WRONG IMPLEMENTATION: leaving `keyEquivalentModifierMask` alone on an
        // item that wants ⌥⌘T. The default mask is ⌘ alone, so the item
        // silently registers ⌘T — a different key, belonging to nobody, and
        // the tooltip still advertises ⌥⌘T.
        let items = allItems()
        for command in EditorCommand.allCases {
            let matches = items.filter {
                $0.keyEquivalent == command.key
                    && $0.keyEquivalentModifierMask == command.modifiers
            }
            #expect(!matches.isEmpty,
                    "\(command.label) advertises \(command.display) and no menu item registers it")
        }
    }

    @Test("No two commands claim the same key")
    func keysAreDistinct() {
        // ⌘C is Copy and ⌘S is Save, which is why crop and the panel take the
        // option-ed forms. A collision inside this list would be the same
        // mistake one level down.
        let combinations = EditorCommand.allCases.map {
            "\($0.key)|\($0.modifiers.rawValue)"
        }
        #expect(Set(combinations).count == combinations.count,
                "two commands registered the same key: \(combinations)")
    }

    @Test("No command collides with a key the app already had")
    func keysDoNotCollideWithTheRestOfTheApp() {
        // Save, Copy, Export and the rest were here first. A new command
        // stealing one of those keys would be found by the person whose Save
        // stopped working, not by a build failure.
        let owned = Set(EditorCommand.allCases.map { "\($0.key)|\($0.modifiers.rawValue)" })
        var seen: [String: Int] = [:]
        for item in allItems() where !item.keyEquivalent.isEmpty {
            let id = "\(item.keyEquivalent)|\(item.keyEquivalentModifierMask.rawValue)"
            seen[id, default: 0] += 1
        }
        for id in owned {
            #expect(seen[id, default: 0] <= 1,
                    "\(id) is registered by more than one menu item")
        }
    }

    @Test("The shortcut a tooltip advertises is spelled from the key it registers")
    func tooltipsQuoteTheRealKey() {
        // The whole point of the type: `display` is DERIVED from `key` and
        // `modifiers`, so it cannot describe a different shortcut from the one
        // the menu item is built with.
        //
        // WRONG IMPLEMENTATION: a hand-typed `display` string. Verified to
        // fail by returning "⌘X" from it — every expectation below breaks,
        // because the glyphs stop matching the modifiers beside them.
        #expect(EditorCommand.export.display == "⌘E")
        #expect(EditorCommand.autoTrim.display == "⌥⌘T")
        #expect(EditorCommand.crop.display == "⌥⌘C")
        #expect(EditorCommand.resetCrop.display == "⌥⇧⌘C")
        #expect(EditorCommand.panel.display == "⌥⌘S")

        for command in EditorCommand.allCases {
            #expect(command.tooltip == "\(command.label) (\(command.display))",
                    "\(command.label)'s tooltip is not name-then-key")
            #expect(command.tooltip.hasSuffix("(\(command.display))"),
                    "\(command.label)'s tooltip does not end in the shortcut")
        }
    }

    @Test("Modifier glyphs are in Apple's order")
    func glyphOrder() {
        // ⌃⌥⇧⌘, which is what every other Mac menu shows. Reset Crop is the
        // only one here with three, so it is the only one that can catch this.
        #expect(EditorCommand.resetCrop.display == "⌥⇧⌘C")
    }
}
