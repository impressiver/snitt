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
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        item.submenu = menu
        return item
    }

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
        item.submenu = menu
        return item
    }

    private static func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: "Help")
        return item
    }
}
