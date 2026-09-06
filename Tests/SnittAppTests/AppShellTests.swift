import Testing
import AppKit
@testable import SnittApp

@Suite(.serialized)
@MainActor
struct AppShellTests {
    init() { _ = NSApplication.shared }

    @Test("The app is a regular app, not an accessory")
    func appIsRegular() {
        AppShell.install(into: NSApplication.shared)
        // Assert the OBSERVABLE policy, not that a setter ran. A test that
        // spies on setActivationPolicy passes against an implementation that
        // sets it and is then overridden by something else.
        #expect(NSApp.activationPolicy() == .regular)
    }

    @Test("Installing actually assigns the built menu as the app's main menu")
    func installAssignsMainMenu() {
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

    @Test("Installing wires the Window and Help menus so AppKit can auto-populate them")
    func installAssignsWindowsAndHelpMenus() {
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

    @Test("The main menu has the standard top-level menus")
    func mainMenuHasStandardStructure() {
        let menu = AppShell.buildMainMenu()
        let titles = menu.items.map(\.title)
        #expect(titles.contains("File"))
        #expect(titles.contains("Edit"))
        #expect(titles.contains("Window"))
        #expect(titles.contains("Help"))
    }

    @Test("Settings is on Command-comma, in the app menu")
    func settingsHasStandardShortcut() throws {
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

    @Test("Quit is on Command-Q and actually terminates the app")
    func quitIsWiredToTerminate() throws {
        let menu = AppShell.buildMainMenu()
        let appMenu = try #require(menu.items.first?.submenu)
        let quit = try #require(appMenu.items.first { $0.title.hasPrefix("Quit") })
        #expect(quit.keyEquivalent == "q")
        // Asserting the ACTION, not just the title: a Quit item wired to
        // nothing looks identical in a title-only assertion.
        #expect(quit.action == #selector(NSApplication.terminate(_:)))
    }
}
