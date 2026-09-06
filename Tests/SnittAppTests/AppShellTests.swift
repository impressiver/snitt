import Testing
import AppKit
@testable import SnittApp

/// §4.14's app shell: the main menu, the activation policy, and the File
/// menu's document commands.
///
/// Every body runs inside `EditorWindowTestGate` (whole-branch review F5).
/// This suite is not about windows, but it mutates process-global
/// `NSApplication` state — `install(into:)` calls
/// `setActivationPolicy(.regular)`, and three tests null out
/// `NSApp.mainMenu`/`windowsMenu`/`helpMenu` mid-test — while the four
/// gated editor suites are concurrently calling `makeKeyAndOrderFront(nil)`
/// and `NSApp.activate()`. Mutating global `NSApplication` state from one
/// suite while another orders windows is the same class as the Task 5
/// segfault, one level up, and is the best remaining hypothesis for this
/// milestone's 1-in-9 cross-suite flake. The two tests that only build a
/// menu are gated as well rather than sorted case by case: the property
/// that makes a test safe here ("touches no process-global state") is one
/// line of maintenance away from stopping being true.
@Suite(.serialized)
@MainActor
struct AppShellTests {
    init() { _ = NSApplication.shared }

    @Test("The app is a regular app, not an accessory")
    func appIsRegular() async {
        await EditorWindowTestGate.run {
            AppShell.install(into: NSApplication.shared)
            // Assert the OBSERVABLE policy, not that a setter ran. A test that
            // spies on setActivationPolicy passes against an implementation that
            // sets it and is then overridden by something else.
            #expect(NSApp.activationPolicy() == .regular)
        }
    }

    @Test("Installing actually assigns the built menu as the app's main menu")
    func installAssignsMainMenu() async {
        await EditorWindowTestGate.run {
            // F1: a mutant `install` that builds the menu but never assigns
            // `app.mainMenu` left this suite green — every other test calls
            // `buildMainMenu()` directly and never touches `NSApp.mainMenu`.
            // §4.14 is "the app HAS a main menu," not "a menu CAN be built."
            NSApp.mainMenu = nil
            AppShell.install(into: NSApplication.shared)
            #expect(NSApp.mainMenu != nil)
            let titles = NSApp.mainMenu?.items.map(\.title)
            #expect(titles?.contains("File") == true)
        }
    }

    @Test("Installing wires the Window and Help menus so AppKit can auto-populate them")
    func installAssignsWindowsAndHelpMenus() async {
        await EditorWindowTestGate.run {
            // F3: an unassigned `NSApp.windowsMenu` means the Window menu never
            // gains AppKit's automatic list of open windows; same for Help's
            // search field via `helpMenu`. Built but never assigned is still
            // unasserted.
            NSApp.windowsMenu = nil
            NSApp.helpMenu = nil
            AppShell.install(into: NSApplication.shared)
            #expect(NSApp.windowsMenu?.title == "Window")
            #expect(NSApp.helpMenu?.title == "Help")
        }
    }

    @Test("The main menu has the standard top-level menus")
    func mainMenuHasStandardStructure() async {
        await EditorWindowTestGate.run {
            let menu = AppShell.buildMainMenu()
            let titles = menu.items.map(\.title)
            #expect(titles.contains("File"))
            #expect(titles.contains("Edit"))
            #expect(titles.contains("Window"))
            #expect(titles.contains("Help"))
        }
    }

    @Test("Settings is on Command-comma, in the app menu")
    func settingsHasStandardShortcut() async throws {
        try await EditorWindowTestGate.run {
            let menu = AppShell.buildMainMenu()
            let appMenu = try #require(menu.items.first?.submenu, "first item must be the app menu")
            let settings = try #require(appMenu.items.first { $0.title.hasPrefix("Settings") },
                                        "no Settings item in the app menu")
            // The shortcut is the property that matters: a Settings item nobody
            // can reach by habit is a Settings item nobody reaches.
            #expect(settings.keyEquivalent == ",")
            // Near-vacuous on its own — .command is AppKit's default modifier
            // mask for any item with a non-empty key equivalent — so this line
            // is not what's discriminating here; `keyEquivalent == ","` above is.
            // Kept because a future item that explicitly overrides the mask to
            // something else would still be worth catching.
            #expect(settings.keyEquivalentModifierMask == .command)
        }
    }

    @Test("Quit is on Command-Q and actually terminates the app")
    func quitIsWiredToTerminate() async throws {
        try await EditorWindowTestGate.run {
            let menu = AppShell.buildMainMenu()
            let appMenu = try #require(menu.items.first?.submenu)
            let quit = try #require(appMenu.items.first { $0.title.hasPrefix("Quit") })
            #expect(quit.keyEquivalent == "q")
            // Asserting the ACTION, not just the title: a Quit item wired to
            // nothing looks identical in a title-only assertion.
            #expect(quit.action == #selector(NSApplication.terminate(_:)))
        }
    }

    @Test("File menu has Open on Command-O")
    func fileMenuHasOpen() async throws {
        try await EditorWindowTestGate.run {
            let menu = AppShell.buildMainMenu()
            let file = try #require(menu.items.first { $0.title == "File" }?.submenu)
            let open = try #require(file.items.first { $0.title == "Open…" }, "no Open item")
            #expect(open.keyEquivalent == "o")
            #expect(open.action == #selector(AppDelegate.openDocument(_:)))
        }
    }

    @Test("File menu has an Open Recent submenu")
    func fileMenuHasOpenRecent() async throws {
        try await EditorWindowTestGate.run {
            let menu = AppShell.buildMainMenu()
            let file = try #require(menu.items.first { $0.title == "File" }?.submenu)
            let recent = try #require(file.items.first { $0.title == "Open Recent" })
            #expect(recent.submenu != nil)
        }
    }

    /// F: an Open Recent submenu built once at install time and never
    /// refreshed passes `fileMenuHasOpenRecent` above forever, because that
    /// test only checks the submenu EXISTS — it never opens a document
    /// first. This test is the one that actually exercises staleness: a
    /// submenu built before a document existed must still surface it once
    /// `menuNeedsUpdate(_:)` runs, which is what AppKit calls right before
    /// the submenu is shown.
    @Test("Open Recent's submenu rebuilds via menuNeedsUpdate, not just once at launch")
    func openRecentSubmenuRebuildsOnDemand() async throws {
        try await EditorWindowTestGate.run {
            let url = FileManager.default.temporaryDirectory
                .appending(path: "recent-fixture-\(UUID().uuidString).snitt")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: url)
                // Don't leave this fixture's URL sitting in the maintainer's
                // real recents list (NSDocumentController) beyond this test.
                NSDocumentController.shared.clearRecentDocuments(nil)
            }

            // A submenu as it would look right after launch: built before this
            // document ever existed.
            let staleSubmenu = NSMenu(title: "Open Recent")
            staleSubmenu.addItem(withTitle: "Clear Menu", action: nil, keyEquivalent: "")

            RecentDocuments.note(url)

            let delegate = AppDelegate()
            delegate.menuNeedsUpdate(staleSubmenu)

            let titles = staleSubmenu.items.map(\.title)
            #expect(titles.contains(url.lastPathComponent))
        }
    }
}
