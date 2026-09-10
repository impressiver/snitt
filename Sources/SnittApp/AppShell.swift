// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit

/// The application shell: activation policy and main menu (§4.14, D45).
///
/// Snitt was `.accessory` through M5, with `EditorWindowController`
/// promoting to `.regular` while a window was open and demoting when the
/// last one closed. That came from reading §4.11's "record without opening
/// a window" as "have no application shell" — which it never meant. One is
/// about what a keystroke does; the other is about what the app is.
///
/// §4.11 is unaffected by this file: the hotkey and status item still record
/// with no window. A Dock icon does not require a window.
@MainActor
enum AppShell {
    /// Owns the Window menu's dynamic document list. A single, stable
    /// instance — assigning a fresh delegate on every `install(into:)` call
    /// would still work, but tests build the menu directly (`buildMainMenu`)
    /// without going through `install`, and a shared instance keeps the
    /// delegate assignment inside `windowMenuItem()` itself rather than
    /// requiring both call sites to remember it separately.
    private static let windowMenuDelegate = WindowMenuDelegate()

    static func install(into app: NSApplication) {
        app.setActivationPolicy(.regular)
        let menu = buildMainMenu()
        app.mainMenu = menu
        // Without these, AppKit has no menu to auto-populate: the Window
        // menu's own list of open windows and the Help menu's search field
        // both depend on the app knowing which of `menu`'s items are theirs.
        // Which windows actually show up there — and whether "Bring All to
        // Front" needs more than this — is Task 4/6 scope; unassigned would
        // leave that unasserted either way, so it's assigned regardless.
        app.windowsMenu = menu.item(withTitle: "Window")?.submenu
        app.helpMenu = menu.item(withTitle: "Help")?.submenu
    }

    /// Built separately from `install` so tests can inspect the structure
    /// without mutating the shared `NSApplication`.
    static func buildMainMenu() -> NSMenu {
        let main = NSMenu()
        main.addItem(appMenuItem())
        main.addItem(fileMenuItem())
        main.addItem(editMenuItem())
        // Built by `KeyboardShortcutRegistry` rather than here, so a binding
        // lives in exactly one place — see that type for why a hand-written
        // help dialog beside a hand-written menu is a drift waiting to happen.
        main.addItem(KeyboardShortcutRegistry.playbackMenuItem())
        main.addItem(windowMenuItem())
        main.addItem(helpMenuItem())
        return main
    }

    private static func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Snitt", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Snitt")

        menu.addItem(withTitle: "About Snitt",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(AppDelegate.showSettings(_:)),
                                  keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Hide Snitt",
                     action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Snitt",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        item.submenu = menu
        return item
    }

    private static func fileMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "File")

        let open = NSMenuItem(title: "Open…",
                              action: #selector(AppDelegate.openDocument(_:)),
                              keyEquivalent: "o")
        menu.addItem(open)

        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recent.submenu = RecentDocuments.buildMenu()
        menu.addItem(recent)
        menu.addItem(.separator())

        // Task 8: the missing half of record → trim → share. Nil target —
        // `AppDelegate.exportDocument(_:)` resolves which open editor this
        // is for from `NSApp.keyWindow`, the same nil-target pattern as
        // `Open…` above.
        let export = NSMenuItem(title: "Export…",
                                action: #selector(AppDelegate.exportDocument(_:)),
                                keyEquivalent: "e")
        menu.addItem(export)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Close",
                     action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        item.submenu = menu
        return item
    }

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Edit")
        // Task 7 adds a real UndoManager; these selectors resolve to nothing
        // until then. Left wired so ⌘Z/⌘⇧Z start working the moment it lands.
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        // This "Cut" is TEXT cut (⌘X, `NSText.cut(_:)`) — left exactly as it
        // was. Task 5 (D56) deliberately does NOT repoint it at the timeline:
        // Snitt has no clipboard model for a removed time RANGE, so binding
        // ⌘X to it would promise a paste that does not exist, and this item
        // is the one real text-field cut still in use elsewhere in the app
        // (Settings, the Export panel's filename field).
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        // The keyboard path Task 4's Cut button was missing (Task 5's
        // second fix). Bound to the delete/backspace key — the "remove the
        // selected range" convention NLEs use — rather than reusing ⌘X,
        // for the reason above. Nil target: `EditorWindowController` is not
        // in the responder chain (see `AppDelegate.exportDocument`'s doc
        // comment), so this resolves to `AppDelegate.cutTimelineSelection(_:)`
        // the same way `Export…` resolves to `exportDocument(_:)`.
        // `keyEquivalentModifierMask = []` is what makes a BARE delete
        // press (no ⌘) match; `AppDelegate`'s `NSMenuItemValidation`
        // conformance is what keeps that bare key from swallowing an
        // ordinary Backspace everywhere else in the app — see
        // `EditorWindowController.hasTimelineSelection`'s doc comment.
        let cutSelection = NSMenuItem(title: "Cut Selection",
                                      action: #selector(AppDelegate.cutTimelineSelection(_:)),
                                      keyEquivalent: "\u{8}")
        cutSelection.keyEquivalentModifierMask = []
        menu.addItem(cutSelection)
        item.submenu = menu
        return item
    }

    /// The four items below are the ones every install starts with;
    /// `WindowMenuDelegate` trims back to this count before re-appending
    /// its document list, so a change here must stay in step with
    /// `WindowMenuDelegate.staticItemCount`.
    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front",
                     action: #selector(NSApplication.arrangeInFront(_:)),
                     keyEquivalent: "")
        // AppKit's own automatic Window-menu population (driven by
        // `NSApp.windowsMenu`, assigned in `install(into:)`) depends on a
        // live window server tracking real on-screen windows — it does not
        // reliably fire in a headless test bundle. This delegate is what
        // makes the document list observable and testable directly, the
        // same reason Task 4 put Open Recent behind `menuNeedsUpdate(_:)`
        // instead of trusting a menu built once at install time.
        menu.delegate = windowMenuDelegate
        item.submenu = menu
        return item
    }

    private static func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Help")
        // Rendered from the same array that installed the keys. The dialog
        // cannot describe a binding that does not exist, and a binding cannot
        // exist undocumented.
        menu.addItem(NSMenuItem(title: "Keyboard Shortcuts",
                                action: #selector(AppDelegate.showKeyboardShortcuts(_:)),
                                keyEquivalent: ""))
        item.submenu = menu
        return item
    }
}

/// Keeps the Window menu's list of open editor documents current.
///
/// A menu built once at launch (`AppShell.buildMainMenu`) is permanently
/// stale — it can only ever show the windows that existed at that moment,
/// never one opened afterwards. `menuNeedsUpdate(_:)` is what AppKit calls
/// right before the menu is actually shown, so rebuilding the document list
/// here — rather than trusting whatever `windowMenuItem()` populated it
/// with at install time — is what keeps it live for the life of the app.
/// Mirrors `AppDelegate`'s `NSMenuDelegate` conformance for Open Recent
/// (Task 4) for exactly the same reason.
@MainActor
private final class WindowMenuDelegate: NSObject, NSMenuDelegate {
    /// Minimize, Zoom, a separator, and Bring All to Front — the items
    /// `windowMenuItem()` seeds the menu with before this delegate ever
    /// runs. Everything after this count is this delegate's own and gets
    /// discarded and rebuilt on every call.
    static let staticItemCount = 4

    func menuNeedsUpdate(_ menu: NSMenu) {
        while menu.items.count > Self.staticItemCount {
            menu.removeItem(at: menu.items.count - 1)
        }
        let editors = EditorWindowController.openEditors
        guard !editors.isEmpty else { return }
        menu.addItem(.separator())
        for editor in editors {
            let entry = NSMenuItem(title: editor.window.title,
                                   action: #selector(NSWindow.makeKeyAndOrderFront(_:)),
                                   keyEquivalent: "")
            entry.target = editor.window
            entry.representedObject = editor
            menu.addItem(entry)
        }
    }
}
