// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp

/// D84's registry: one list that both installs the shortcuts and documents
/// them.
///
/// The tests that matter are the ones asserting those two outputs cannot
/// disagree. A registry whose menu and help were merely *similar* would be the
/// hand-written pair it exists to replace.
@Suite(.serialized)
@MainActor
struct KeyboardShortcutRegistryTests {
    init() { _ = NSApplication.shared }

    @Test("Every shortcut in the registry becomes a menu item")
    func menuIsBuiltFromTheRegistry() {
        let item = KeyboardShortcutRegistry.playbackMenuItem()
        // Full equality, separators aside: EVERY playback item comes from the
        // registry, in its order. This briefly weakened to a prefix comparison
        // while Show Clicks was appended outside `shortcuts` — giving it ⇧⌘C
        // moved it in, so the stronger assertion is available again and an
        // item added to the menu but not the registry fails here once more.
        let titles = (item.submenu?.items ?? [])
            .filter { !$0.isSeparatorItem }.map(\.title)
        let expected = KeyboardShortcutRegistry.shortcuts
            .filter { $0.menu == .playback }.map(\.title)
        #expect(titles == expected)
    }

    @Test("Every shortcut in the registry appears in the help")
    func helpIsRenderedFromTheRegistry() {
        // The drift this type exists to prevent. A binding present in the menu
        // and missing from the help is the `ServerInstructionsTests` failure
        // one surface over — instructions describing tools that had moved.
        let help = KeyboardShortcutRegistry.helpText
        for shortcut in KeyboardShortcutRegistry.shortcuts {
            #expect(help.contains(shortcut.title), "\(shortcut.title) is bound but undocumented")
        }
    }

    @Test("The help and the menu carry the SAME key for each action")
    func helpAndMenuAgreeOnEveryKey() {
        // Not "both mention Play/Pause" — the same key equivalent and the same
        // modifiers. Two surfaces naming one action with different keys is
        // exactly the drift a shared source is supposed to make impossible,
        // and asserting only that both lists are non-empty would miss it.
        let menu = KeyboardShortcutRegistry.playbackMenuItem().submenu?.items ?? []
        for shortcut in KeyboardShortcutRegistry.shortcuts where shortcut.menu == .playback {
            let entry = menu.first { $0.title == shortcut.title }
            #expect(entry?.keyEquivalent == shortcut.key)
            #expect(entry?.keyEquivalentModifierMask == shortcut.modifiers)
            #expect(KeyboardShortcutRegistry.helpText
                .contains(KeyboardShortcutRegistry.display(of: shortcut)))
        }
    }

    @Test("Space is documented by name, not as an invisible character")
    func spaceIsNamed() {
        // The single most important binding to document, and the one that
        // renders as nothing at all if printed literally — a help line reading
        // "  \tPlay / Pause" describes no key.
        #expect(KeyboardShortcutRegistry.keyName(" ") == "Space")
        #expect(KeyboardShortcutRegistry.helpText.contains("Space"))
    }

    @Test("Arrow keys render as arrows, not as private-use garbage")
    func arrowsAreReadable() {
        // `NSLeftArrowFunctionKey` is a private-use code point. Printed raw it
        // is an empty box in the help dialog.
        let help = KeyboardShortcutRegistry.helpText
        #expect(help.contains("⌥←"))
        #expect(help.contains("⌥→"))
    }

    @Test("Play/Pause is one binding, not a Play and a Pause")
    func playbackIsASingleToggle() {
        // The editor shipped Play and Pause as separate buttons, so one of
        // them was always a no-op. The registry must not reintroduce that as
        // two separate keys.
        let titles = KeyboardShortcutRegistry.shortcuts.map(\.title)
        #expect(titles.contains("Play / Pause"))
        #expect(!titles.contains("Play"))
        #expect(!titles.contains("Pause"))
    }

    @Test("Bare keys carry an empty modifier mask, or they need ⌘ to fire")
    func bareKeysAreActuallyBare() {
        // `keyEquivalentModifierMask` defaults to `.command`. A Space binding
        // that inherited that default would need ⌘Space — which is Spotlight,
        // and would never reach this app at all.
        let space = KeyboardShortcutRegistry.shortcuts.first { $0.key == " " }
        #expect(space?.modifiers.isEmpty == true)
        let menu = KeyboardShortcutRegistry.playbackMenuItem().submenu?.items ?? []
        let spaceItem = menu.first { $0.keyEquivalent == " " }
        #expect(spaceItem?.keyEquivalentModifierMask.isEmpty == true)
    }

    @Test("No two shortcuts claim the same key")
    func bindingsAreUnique() {
        // A duplicate means one of them silently never fires, and which one is
        // an AppKit implementation detail.
        let keys = KeyboardShortcutRegistry.shortcuts.map { "\($0.modifiers.rawValue)-\($0.key)" }
        #expect(Set(keys).count == keys.count, "two shortcuts share a key")
    }

    @Test("Every shortcut names an action the app delegate actually implements")
    func selectorsResolve() {
        // A registry entry pointing at a selector nobody implements installs a
        // permanently-disabled menu item — live-looking, and doing nothing.
        for shortcut in KeyboardShortcutRegistry.shortcuts {
            #expect(AppDelegate.instancesRespond(to: shortcut.selector),
                    "\(shortcut.title) is bound to an unimplemented selector")
        }
    }
}
