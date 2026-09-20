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
        for shortcut in KeyboardShortcutRegistry.allShortcuts {
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
        //
        // `allShortcuts`, not `shortcuts`. This read the Playback list alone
        // while Edit, View and File entries existed beside it — so the one
        // check that makes a new binding safe to add was blind to every menu
        // a new binding was likely to land in.
        let keys = KeyboardShortcutRegistry.allShortcuts
            .map { "\($0.modifiers.rawValue)-\($0.key)" }
        #expect(Set(keys).count == keys.count, "two shortcuts share a key")
    }

    @Test("Every shortcut names an action the app delegate actually implements")
    func selectorsResolve() {
        // A registry entry pointing at a selector nobody implements installs a
        // permanently-disabled menu item — live-looking, and doing nothing.
        for shortcut in KeyboardShortcutRegistry.allShortcuts {
            #expect(AppDelegate.instancesRespond(to: shortcut.selector),
                    "\(shortcut.title) is bound to an unimplemented selector")
        }
    }
    @Test("Every menu the registry assembles gets its items")
    func assembledMenusAreComplete() {
        // The Playback test above pins one menu by name. Edit and View arrived
        // later and would have had no such check, which is how a binding ends
        // up in the help and in no menu at all.
        for menu in KeyboardShortcut.Menu.allCases {
            let expected = KeyboardShortcutRegistry.assembledShortcuts
                .filter { $0.menu == menu }.map(\.title)
            guard !expected.isEmpty else { continue }
            let built = KeyboardShortcutRegistry.items(in: menu)
                .filter { !$0.isSeparatorItem }.map(\.title)
            #expect(built == expected, "\(menu.rawValue) is not built from the registry")
        }
    }

    @Test("A hand-built menu's binding is documented but not assembled twice")
    func fileShortcutsAreNotDuplicated() {
        // WRONG IMPLEMENTATION: putting Export… in the list the menu builders
        // read. `AppShell.fileMenuItem` already owns its position among Save,
        // Share and Close, so a second one appears in another menu AND makes
        // ⌘E ambiguous — which is the one outcome `bindingsAreUnique` cannot
        // see, because both entries would be the same entry.
        let assembled = KeyboardShortcutRegistry.assembledShortcuts.map(\.title)
        #expect(!assembled.contains(KeyboardShortcutRegistry.exportTitle))
        #expect(KeyboardShortcutRegistry.helpText
            .contains(KeyboardShortcutRegistry.exportTitle),
            "Export's key is registered nowhere a person can read it")
    }

    @Test("Over-dub is an edit, not a playback control")
    func overdubIsAnEdit() {
        // It records a take INTO the document. Playback is where you are in
        // the recording and what is drawn over it; nothing there changes what
        // the file contains.
        let overdub = KeyboardShortcutRegistry.allShortcuts
            .first { $0.title == KeyboardShortcutRegistry.overdubTitle }
        #expect(overdub?.menu == .edit)
    }

    @Test("A toolbar tooltip quotes the key the registry registered")
    func tooltipsAreLookedUp() {
        // The failure this prevents: a button advertising a shortcut the menus
        // never registered, found out by pressing the key and having nothing
        // happen. Every titlebar button reads its key through
        // `shortcutDisplay(titled:)`, so a title that stops matching shows the
        // label alone rather than a stale key.
        for title in [KeyboardShortcutRegistry.autoTrimTitle,
                      KeyboardShortcutRegistry.cropTitle,
                      KeyboardShortcutRegistry.panelTitle,
                      KeyboardShortcutRegistry.exportTitle] {
            #expect(!KeyboardShortcutRegistry.shortcutDisplay(titled: title).isEmpty,
                    "\(title) has no key, so its button's tooltip is bare")
        }
        #expect(KeyboardShortcutRegistry.shortcutDisplay(
            titled: KeyboardShortcutRegistry.exportTitle) == "⌘E")
        #expect(KeyboardShortcutRegistry.shortcutDisplay(titled: "nothing claims this") == "")
    }
    @Test("Every tooltip is label-then-key in parentheses")
    func tooltipFormatIsOneStyle() {
        // It was written at four call sites, two with an em dash and two with
        // parentheses, so hovering two buttons in the same row gave two house
        // styles. One function builds it now.
        // The FORMAT is what is pinned, not the binding. Spelling the key out
        // here made this test fail when Back to Start moved from Home to ⌘←,
        // which is a rebinding rather than a formatting regression — and a
        // test that cries about the wrong thing gets edited until it stops.
        let key = KeyboardShortcutRegistry.shortcutDisplay(titled: "Back to Start")
        #expect(!key.isEmpty, "the registry lost its Back to Start binding")
        let rendered = KeyboardShortcutRegistry.tooltip(
            "Back to start", key: "Back to Start")
        #expect(rendered == "Back to start (\(key))")
        #expect(!rendered.contains("—"), "the em dash is back")

        // And a title nothing claims degrades to the bare label rather than
        // to a dangling "()" or a stale key.
        #expect(KeyboardShortcutRegistry.tooltip("Orphan", key: "no such command")
                == "Orphan")
    }

    @Test("Every control the product owner asked for has a key")
    func theRequestedCommandsAreAllBound() {
        // Listed by name rather than counted, so adding a binding does not
        // quietly satisfy a missing one.
        for title in [KeyboardShortcutRegistry.cutSelectionTitle,
                      KeyboardShortcutRegistry.addMarkerTitle,
                      KeyboardShortcutRegistry.addNarrationTitle,
                      KeyboardShortcutRegistry.zoomInTitle,
                      KeyboardShortcutRegistry.zoomOutTitle,
                      "Back to Start"] {
            #expect(!KeyboardShortcutRegistry.shortcutDisplay(titled: title).isEmpty,
                    "\(title) has no key, so its button's tooltip is bare")
        }
    }
}
