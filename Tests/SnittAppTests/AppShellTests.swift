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
