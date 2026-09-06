# M5c: The App Shell — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Snitt from a menu-bar accessory into a standard macOS desktop app that can open its own `.snitt` documents.

**Architecture:** The app becomes permanently `.regular` with a real `NSApp.mainMenu`, keeping the status item as the fast path. The existing private `RecordingCoordinator.openEditor(for:)` is extracted into a reusable `DocumentOpener` so an editor can be created from any bundle URL — from a finished recording, from File ▸ Open, from Open Recent, or from a Finder double-click. `.snitt` is declared as an exported UTI conforming to `com.apple.package`. A Settings window consolidates four settings currently living as status-item toggles.

**Tech Stack:** AppKit (`NSApplication`, `NSMenu`, `NSWindowController`, `NSDocumentController` for the recents list only), Swift 6 strict concurrency, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-02-snitt-design.md` — §4.14 (app shape) and decision D45 are the direct authority; §4.5, §4.7, §4.11, §5, §6 constrain it.

## Global Constraints

- **§4.11 is preserved exactly.** The global hotkey and the menu-bar item start and stop recording with **no window opening**. A Dock icon does not require a window. Any change that opens a window on record is a defect, not a side effect.
- **The menu-bar item stays.** It is the fast path, not a legacy surface. Do not remove it or fold it into the main menu.
- **§5 consent behaviour is unchanged.** `ConsentExplainer` gating on the hotkey path is consent behaviour. The picker appears on **every** recording (D42). Do not touch either.
- **§6's three-frontend architecture is unchanged.** The GUI is one frontend among three; `snitt-cli` and `snitt-mcp` keep driving the same core. Nothing in this milestone may make the GUI a dependency of `SnittAutomation`.
- **Swift 6, strict concurrency, zero warnings** from `Sources/` under `swift build -Xswiftc -strict-concurrency=complete`.
- **Privacy in logging.** This project has leaked user data through `os_log` twice — an interpolated filename, and `String(describing:)` on an `NSError`, which serialises `userInfo` including `NSFilePath`. `privacy: .public` goes only on `domain`, `code`, `localizedDescription`. Never interpolate a path or URL. Never `String(describing:)` an error. Bundle filenames are derived from the git branch (`BundleNaming`) and are themselves sensitive.
- **Settings default to off** and a corrupt or absent stored value reads as off. Absent and invalid are different states; both are not-on.

### Verification traps (apply to every task)

- `swift test` **exits 0 when the test bundle segfaults** — an inline `error: … signal code 11`, and then **no summary line**. Piping to `grep` returns grep's exit status. **Only `Test run with N tests … passed/failed` is trustworthy.** Run the suite twice.
- `timeout` does not exist on macOS.
- **`NSApp` is nil in a test bundle** until `NSApplication.shared` is touched. A suite needing it uses `@Suite(.serialized)` with `init() { _ = NSApplication.shared }`.
- **No test may mutate the process-global current directory.** That race was closed structurally; reintroducing it silently skips unrelated tests.
- **No test may write to the real home or preference domain.** Verify by comparing the **mtime** of `~/Library/Preferences/com.impressiver.snitt.plist` before and after a full run — mtime proves no write occurred, where value-equality does not.
- **`make-app.sh`'s Info.plist heredoc is unquoted** (so `$APP_VERSION` expands), which means **backticks inside it execute as commands**. Two tests pin this. New plist content must not reintroduce one.

### Testing standard

Every test names a plausible wrong implementation and is **verified to fail against it**. Assert the target string was found before mutating, grep the mutated file before running, restore the tree afterwards.

This project has found **twenty-six** instances of a test verifying a property *adjacent* to the one that mattered — one passing only on leftover machine state, one two-test composition a single mutant walked through, one asserting against a literal the test itself wrote, and one whose fixture silently chose which property got tested.

Menus and activation policy are unusually prone to this:

- Asserting *"a menu item titled Open exists"* is **not** asserting *"⌘O opens a document."*
- Asserting *"`setActivationPolicy(.regular)` was called"* is **not** asserting *"the app is a regular app"* — assert `NSApp.activationPolicy()`.
- Asserting *"the plist has a document type"* is **not** asserting *"the declared type matches the exported UTI"* — two strings that must agree, in the same class as the `SUFeedURL` ↔ `appcast.xml` drift M5b had to pin.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/SnittApp/AppShell.swift` *(new)* | Activation policy + main menu construction. One entry point, `AppShell.install(into:)`, callable from tests. |
| `Sources/SnittApp/DocumentOpener.swift` *(new)* | Bundle URL → open editor window. Extracted from `RecordingCoordinator.openEditor(for:)`; the single path every caller uses. |
| `Sources/SnittApp/RecentDocuments.swift` *(new)* | Wraps `NSDocumentController` recents so the Open Recent menu is buildable and testable without `NSDocument`. |
| `Sources/SnittApp/SettingsWindowController.swift` *(new)* | ⌘, window hosting the four settings. |
| `Sources/SnittApp/main.swift` | `.regular` at startup; installs the main menu; `application(_:open:)` for Finder. |
| `Sources/SnittApp/EditorWindowController.swift` | Drops the promote/demote activation dance (now always `.regular`). |
| `Sources/SnittApp/RecordingCoordinator.swift` | `openEditor(for:)` delegates to `DocumentOpener`. |
| `Scripts/make-app.sh` | Exported UTI + `CFBundleDocumentTypes`. |
| `Tests/SnittAppTests/AppShellTests.swift` *(new)* | Activation policy, menu structure, key equivalents. |
| `Tests/SnittAppTests/DocumentOpenerTests.swift` *(new)* | A real `.snitt` fixture actually opens; failures surface. |
| `Tests/SnittAppTests/BundleLayoutTests.swift` | Document-type ↔ UTI agreement in the built plist. |

---

## Task 1: Permanent `.regular` activation, and the main menu

**Files:**
- Create: `Sources/SnittApp/AppShell.swift`
- Modify: `Sources/SnittApp/main.swift:261` (the `.accessory` call), `Sources/SnittApp/EditorWindowController.swift:256-259` (`applyActivationPolicy`)
- Test: `Tests/SnittAppTests/AppShellTests.swift`

**Interfaces:**
- Produces: `enum AppShell { static func install(into app: NSApplication) }` — sets `.regular` and assigns `app.mainMenu`. Also `static func buildMainMenu() -> NSMenu` so tests can inspect structure without mutating `NSApp`.
- Consumes: nothing from other tasks.

**Why this task exists:** §4.14. The app currently has no `NSApp.mainMenu` at all — the only `NSMenu` is the status item's. `EditorWindowController` promotes to `.regular` while a window is open and demotes back, so the app's shape flickers with window count.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import AppKit
@testable import SnittApp

@Suite(.serialized)
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
```

- [ ] **Step 2: Run it and watch it fail**

```bash
swift test --filter AppShellTests 2>&1 | grep -E "Test run with|error:"
```

Expected: FAIL — `AppShell` does not exist.

- [ ] **Step 3: Write `AppShell`**

```swift
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
        app.mainMenu = buildMainMenu()
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
        let item = NSMenuItem()
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
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")
        // File ▸ Open and Open Recent are filled in by Task 4, which owns
        // the open path. Kept as its own task so a reviewer can reject the
        // opening behaviour without rejecting the shell.
        menu.addItem(withTitle: "Close",
                     action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        item.submenu = menu
        return item
    }

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
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
        let item = NSMenuItem()
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
        let item = NSMenuItem()
        item.submenu = NSMenu(title: "Help")
        return item
    }
}
```

Add to `AppDelegate` (the Settings action is filled in by Task 5; it must exist now so the selector resolves):

```swift
    /// Task 5 replaces this body with the real Settings window. It exists
    /// here so the menu's selector resolves and ⌘, is not silently dead.
    @objc func showSettings(_ sender: Any?) {
        NSSound.beep()
    }
```

- [ ] **Step 4: Replace the `.accessory` call**

In `main.swift`, replace `app.setActivationPolicy(.accessory)` with:

```swift
let app = NSApplication.shared
AppShell.install(into: app)
```

And update the file's header comment, which currently says *"An accessory app: no Dock icon, no window at launch"* — the second half is still true, the first is not. It must read:

```swift
/// A regular app (§4.14, D45): Dock icon and main menu always present, and
/// still no window at launch. §4.11 requires that recording start from a
/// keystroke without a window ever opening — that is about what the hotkey
/// does, not about whether the app has a shell.
```

- [ ] **Step 5: Delete the promote/demote dance**

`EditorWindowController.applyActivationPolicy()` (lines 256-259) exists only to flip between `.accessory` and `.regular` by window count. The app is now always `.regular`. Delete the method and its call sites, and the doc comment at lines 156-161 that explains the accessory workaround.

**Check for orphans after deleting.** A previous cleanup in this project removed a dead switch arm and left `reference(from:)` behind with no compiler warning. Grep for now-unreferenced helpers.

- [ ] **Step 6: Verify — including that §4.11 still holds**

```bash
swift build -Xswiftc -strict-concurrency=complete 2>&1 | grep -E "warning:|error:"
swift test 2>&1 | grep -E "Test run with|signal code|error:"
./Scripts/make-app.sh && open build/Snitt.app
```

Then **by hand**, and record the result in the report: press the record hotkey and confirm **no window opens** and the picker appears. This is §4.11 and no automated test in this plan covers it.

- [ ] **Step 7: Mutation-verify**

Change `install` to set `.accessory`. `appIsRegular` must fail. Restore. Then remove the `keyEquivalent: ","` from Settings; `settingsHasStandardShortcut` must fail. Restore.

- [ ] **Step 8: Commit**

```bash
git add Sources/SnittApp/AppShell.swift Sources/SnittApp/main.swift \
        Sources/SnittApp/EditorWindowController.swift Tests/SnittAppTests/AppShellTests.swift
git commit -m "feat(shell): a regular app with a main menu, not an accessory"
```

---

## Task 2: Extract the document open path

**Files:**
- Create: `Sources/SnittApp/DocumentOpener.swift`
- Modify: `Sources/SnittApp/RecordingCoordinator.swift:495-520` (`openEditor(for:)`)
- Test: `Tests/SnittAppTests/DocumentOpenerTests.swift`

**Interfaces:**
- Produces: `@MainActor enum DocumentOpener { static func open(bundleURL: URL) async throws -> EditorWindowController }` and `static func open(bundle: SnittBundle) async throws -> EditorWindowController`.
- Consumes: `AppShell` from Task 1 (only in that the app is `.regular`).

**Why this task exists:** `RecordingCoordinator.openEditor(for:)` is already a general bundle → editor path. It is private and called from exactly one place — the end of a recording. **That is the whole reason a `.snitt` file cannot be reopened.** Extracting it is the milestone's load-bearing change; Tasks 3 and 4 only give it entry points.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import AppKit
import Foundation
@testable import SnittApp
@testable import SnittDocument

@Suite(.serialized)
struct DocumentOpenerTests {
    init() { _ = NSApplication.shared }

    /// Builds a real `.snitt` bundle on disk in a temp directory. Not a mock:
    /// the property under test is that a bundle written by Snitt can be read
    /// back and opened, and a fake bundle would test the fake.
    private func makeFixtureBundle() throws -> URL { /* see Step 3 */ }

    @Test("A .snitt bundle on disk opens into an editor window")
    func opensARealBundle() async throws {
        let url = try makeFixtureBundle()
        defer { try? FileManager.default.removeItem(at: url) }

        let before = EditorWindowController.openWindowCount
        let controller = try await DocumentOpener.open(bundleURL: url)
        defer { controller.close() }

        // Assert the OUTCOME — a window exists — not that a function was
        // called. "openEditor was invoked" passes against an implementation
        // that throws inside and swallows it.
        #expect(EditorWindowController.openWindowCount == before + 1)
        #expect(controller.window.title == url.lastPathComponent)
    }

    @Test("Opening a path that is not a .snitt bundle throws rather than opening an empty window")
    func rejectsNonBundle() async throws {
        let junk = FileManager.default.temporaryDirectory
            .appending(path: "not-a-bundle-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }

        let before = EditorWindowController.openWindowCount
        await #expect(throws: (any Error).self) {
            _ = try await DocumentOpener.open(bundleURL: junk)
        }
        // The failure that matters is a half-open editor showing nothing.
        #expect(EditorWindowController.openWindowCount == before)
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

```bash
swift test --filter DocumentOpenerTests 2>&1 | grep -E "Test run with|error:"
```

Expected: FAIL — `DocumentOpener` does not exist.

- [ ] **Step 3: Write the fixture helper**

Read `Tests/SnittAppTests/` for an existing `.snitt` fixture builder before writing a new one — several suites already construct bundles. If one exists, use it. If not:

```swift
    private func makeFixtureBundle() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "fixture-\(UUID().uuidString).snitt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = SnittBundle(url: root)
        // Write the minimum a bundle needs to be openable: metadata, an
        // empty event log, and a full-range EDL.
        try RecordingMetadata.placeholderForTests().write(to: bundle)
        try EventLog(events: []).write(to: bundle)
        try EditDecisionList.fullRange().write(to: bundle)
        return root
    }
```

If `RecordingMetadata` has no test helper, write the minimum real metadata its `read(from:)` requires — **do not** add a production convenience initialiser just for tests.

- [ ] **Step 4: Write `DocumentOpener`**

Move the body of `RecordingCoordinator.openEditor(for:)` verbatim, then make the error path throw instead of only logging:

```swift
import AppKit
import Foundation
import SnittDocument
import SnittExport

/// Opens a `.snitt` bundle into an editor window (§4.14).
///
/// This was `RecordingCoordinator.openEditor(for:)` — private, and called
/// from exactly one place: the end of a recording. That is why a bundle
/// could be written and never reopened (D45). Every caller now shares this
/// path: a finished recording, File ▸ Open, Open Recent, and a Finder
/// double-click.
@MainActor
enum DocumentOpener {
    // The project's logger factory — do NOT construct `Logger(subsystem:)`
    // directly. `SnittLog.logger` is the one place that names Snitt's
    // subsystems (M5a), and a hand-rolled Logger would be invisible to
    // `snitt diagnostics export`.
    private static let log = SnittLog.logger(.automation, target: "SnittApp")

    static func open(bundleURL: URL) async throws -> EditorWindowController {
        try await open(bundle: SnittBundle(url: bundleURL))
    }

    static func open(bundle: SnittBundle) async throws -> EditorWindowController {
        let edl = (try? EditDecisionList.read(from: bundle)) ?? .fullRange()
        let events = try EventLog.read(from: bundle).events
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        let jumpPoints = MarkerJumpPoints.compute(events: events, keptRanges: built.keptRanges)

        let controller = PreviewController(built: built, jumpPoints: jumpPoints,
                                           bundle: bundle, scale: 1.0)
        let editor = EditorWindowController(controller: controller,
                                            title: bundle.url.lastPathComponent,
                                            edl: edl, events: events)
        editor.show()
        return editor
    }
}
```

- [ ] **Step 5: Point `RecordingCoordinator` at it**

Replace `openEditor(for:)`'s body with a call to `DocumentOpener.open(bundle:)`, keeping its existing `catch` and its logging **exactly as-is**. That `catch` carries a deliberate redaction: the bundle filename is derived from the git branch, so `feat/acme-corp-integration` names a customer. Do not "simplify" it into interpolating the path.

- [ ] **Step 6: Verify**

```bash
swift build -Xswiftc -strict-concurrency=complete 2>&1 | grep -E "warning:|error:"
swift test 2>&1 | grep -E "Test run with|signal code|error:"
```

- [ ] **Step 7: Mutation-verify**

Make `open(bundle:)` return the controller **without** calling `editor.show()`. `opensARealBundle` must fail on the window count. Restore. Then make the non-bundle path swallow its error and open an empty editor; `rejectsNonBundle` must fail. Restore.

- [ ] **Step 8: Commit**

```bash
git add Sources/SnittApp/DocumentOpener.swift Sources/SnittApp/RecordingCoordinator.swift \
        Tests/SnittAppTests/DocumentOpenerTests.swift
git commit -m "feat(shell): one path from a .snitt bundle to an editor window"
```

---

## Task 3: Declare `.snitt` as a document type

**Files:**
- Modify: `Scripts/make-app.sh` (the Info.plist heredoc)
- Test: `Tests/SnittAppTests/BundleLayoutTests.swift`

**Interfaces:**
- Produces: the UTI string `com.impressiver.snitt.recording`, used by Task 4's open panel.
- Consumes: nothing.

**Why this task exists:** the Finder has no idea what a `.snitt` is. Without an exported UTI and `CFBundleDocumentTypes`, double-clicking does nothing, and an `NSOpenPanel` cannot filter for it.

**A `.snitt` is a directory**, so it must conform to `com.apple.package` or the Finder shows it as a folder and users navigate *into* it instead of opening it.

- [ ] **Step 1: Write the failing test**

```swift
@Test("The built app declares .snitt as an openable package type", .enabled(if: appIsBuilt || requireAppBundle, appBundleSkipReason))
func infoPlistDeclaresDocumentType() throws {
    try #require(appIsBuilt, appBundleSkipReason)
    let plist = try plistOf(app)

    let exported = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
    let snitt = try #require(exported.first { ($0["UTTypeIdentifier"] as? String) == "com.impressiver.snitt.recording" },
                             "no exported UTI for .snitt")

    // A .snitt is a DIRECTORY. Without com.apple.package the Finder shows a
    // folder and a double-click navigates into it instead of opening it —
    // the app looks broken while every key is nominally present.
    let conforms = try #require(snitt["UTTypeConformsTo"] as? [String])
    #expect(conforms.contains("com.apple.package"))

    let tags = try #require(snitt["UTTypeTagSpecification"] as? [String: Any])
    let extensions = try #require(tags["public.filename-extension"] as? [String])
    #expect(extensions.contains("snitt"))

    let docTypes = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
    let docType = try #require(docTypes.first, "no CFBundleDocumentTypes entry")
    let contentTypes = try #require(docType["LSItemContentTypes"] as? [String])

    // The two must AGREE. A document type naming a UTI the app does not
    // export is the same silent-drift class as SUFeedURL vs appcast.xml:
    // both halves look right in isolation and nothing opens.
    #expect(contentTypes.contains("com.impressiver.snitt.recording"))
    #expect(docType["CFBundleTypeRole"] as? String == "Editor")
    #expect(docType["LSTypeIsPackage"] as? Bool == true)
}
```

- [ ] **Step 2: Run it and watch it fail**

```bash
./Scripts/make-app.sh
swift test --filter infoPlistDeclaresDocumentType 2>&1 | grep -E "Test run with|error:"
```

Expected: FAIL — no `UTExportedTypeDeclarations` key.

- [ ] **Step 3: Add the keys to the heredoc**

**Use no backticks.** The heredoc delimiter is unquoted so `$APP_VERSION` expands, which means a backtick runs as a command and its output silently replaces the text. Two tests pin this; do not become the third finding.

```xml
  <!-- A .snitt is a DIRECTORY bundle, so the exported type must conform to
       com.apple.package. Without that the Finder presents it as a folder and
       a double-click navigates into it rather than opening Snitt — every key
       below is present and nothing works. -->
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.impressiver.snitt.recording</string>
      <key>UTTypeDescription</key><string>Snitt Recording</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>com.apple.package</string>
        <string>public.composite-content</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array><string>snitt</string></array>
      </dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Snitt Recording</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSTypeIsPackage</key><true/>
      <key>LSItemContentTypes</key>
      <array><string>com.impressiver.snitt.recording</string></array>
    </dict>
  </array>
```

- [ ] **Step 4: Rebuild and verify**

```bash
./Scripts/make-app.sh 2>&1 | grep -i "command not found" && echo "BACKTICK BUG REINTRODUCED"
swift test 2>&1 | grep -E "Test run with|signal code|error:"
```

- [ ] **Step 5: Mutation-verify**

Change `LSItemContentTypes` to `com.impressiver.snitt.wrong`, rebuild, and confirm the agreement assertion fails — that is the drift this test exists to catch. Restore. Then remove `com.apple.package` from `UTTypeConformsTo`, rebuild, confirm failure. Restore.

- [ ] **Step 6: Verify by hand and record it**

Register the app and double-click a real `.snitt` bundle in the Finder. Launch Services caches aggressively, so register explicitly first:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f build/Snitt.app
```

Report whether the Finder shows it as a single document (correct) or a folder (the `com.apple.package` failure). **This cannot be asserted in the suite** — say so in the report rather than implying coverage.

- [ ] **Step 7: Commit**

```bash
git add Scripts/make-app.sh Tests/SnittAppTests/BundleLayoutTests.swift
git commit -m "feat(shell): declare .snitt as an openable package type"
```

---

## Task 4: File ▸ Open, Open Recent, and Finder double-click

**Files:**
- Create: `Sources/SnittApp/RecentDocuments.swift`
- Modify: `Sources/SnittApp/AppShell.swift` (the File menu), `Sources/SnittApp/main.swift` (`AppDelegate`)
- Test: `Tests/SnittAppTests/AppShellTests.swift`, `Tests/SnittAppTests/DocumentOpenerTests.swift`

**Interfaces:**
- Consumes: `DocumentOpener.open(bundleURL:)` (Task 2), the UTI `com.impressiver.snitt.recording` (Task 3).
- Produces: `enum RecentDocuments { static func note(_ url: URL); static func urls() -> [URL]; static func buildMenu() -> NSMenu }`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("File menu has Open on Command-O")
func fileMenuHasOpen() throws {
    let menu = AppShell.buildMainMenu()
    let file = try #require(menu.items.first { $0.title == "File" }?.submenu)
    let open = try #require(file.items.first { $0.title == "Open…" }, "no Open item")
    #expect(open.keyEquivalent == "o")
    #expect(open.action == #selector(AppDelegate.openDocument(_:)))
}

@Test("File menu has an Open Recent submenu")
func fileMenuHasOpenRecent() throws {
    let menu = AppShell.buildMainMenu()
    let file = try #require(menu.items.first { $0.title == "File" }?.submenu)
    let recent = try #require(file.items.first { $0.title == "Open Recent" })
    #expect(recent.submenu != nil)
}

@Test("Opening a bundle records it in the recent documents list")
func openingNotesARecentDocument() async throws {
    let url = try makeFixtureBundle()
    defer { try? FileManager.default.removeItem(at: url) }

    let controller = try await DocumentOpener.open(bundleURL: url)
    defer { controller.close() }

    // The observable outcome, not "note() was called": a menu built after
    // opening must contain the document.
    #expect(RecentDocuments.urls().contains(url))
}
```

- [ ] **Step 2: Run and watch them fail**

```bash
swift test --filter "fileMenuHasOpen|fileMenuHasOpenRecent|openingNotesARecentDocument" 2>&1 | grep -E "Test run with|error:"
```

- [ ] **Step 3: Write `RecentDocuments`**

`NSDocumentController`'s recents tracking works without any `NSDocument` subclass, which is why this wraps it rather than adopting the document architecture wholesale — Snitt's editor is not an `NSDocument` and making it one is a far larger change than §4.14 asks for.

```swift
import AppKit

/// Recent `.snitt` documents (§4.14).
///
/// Wraps `NSDocumentController` purely for its recents list. Snitt's editor
/// is not an `NSDocument` and this milestone does not make it one — adopting
/// the document architecture is a much larger change than the shell needs.
@MainActor
enum RecentDocuments {
    static func note(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    static func urls() -> [URL] {
        NSDocumentController.shared.recentDocumentURLs
    }

    static func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "Open Recent")
        for url in urls() {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(AppDelegate.openRecentDocument(_:)),
                                  keyEquivalent: "")
            item.representedObject = url
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: "Clear Menu",
                     action: #selector(AppDelegate.clearRecentDocuments(_:)),
                     keyEquivalent: "")
        return menu
    }
}
```

Call `RecentDocuments.note(bundle.url)` from `DocumentOpener.open(bundle:)`, **after** `editor.show()` succeeds — a document that failed to open does not belong in the recents list.

- [ ] **Step 4: Add the File menu items**

In `AppShell.fileMenuItem()`, before `Close`:

```swift
        let open = NSMenuItem(title: "Open…",
                              action: #selector(AppDelegate.openDocument(_:)),
                              keyEquivalent: "o")
        menu.addItem(open)

        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recent.submenu = RecentDocuments.buildMenu()
        menu.addItem(recent)
        menu.addItem(.separator())
```

- [ ] **Step 5: Wire the `AppDelegate` actions**

```swift
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType("com.impressiver.snitt.recording")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        // A .snitt is a package: without this the panel descends into it.
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return }
        openURLs(panel.urls)
    }

    @objc func openRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openURLs([url])
    }

    @objc func clearRecentDocuments(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(sender)
    }

    /// Finder double-click, `open(1)`, and drag-onto-Dock all arrive here.
    func application(_ application: NSApplication, open urls: [URL]) {
        openURLs(urls)
    }

    private func openURLs(_ urls: [URL]) {
        for url in urls {
            Task { @MainActor in
                do {
                    _ = try await DocumentOpener.open(bundleURL: url)
                } catch {
                    // Privacy: the bundle filename comes from the git branch
                    // (BundleNaming), so it can name a customer or an
                    // unreleased feature. Domain/code/description only.
                    let ns = error as NSError
                    Self.log.error("Could not open the document: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .public)")
                    presentOpenFailure(error)
                }
            }
        }
    }
```

`presentOpenFailure` shows an `NSAlert`. A double-click that does nothing at all is the failure users report as "the app is broken."

- [ ] **Step 6: Rebuild the Open Recent submenu when it opens**

A submenu built once at launch never updates. Make `AppDelegate` the `NSMenuDelegate` of the Open Recent submenu and rebuild in `menuNeedsUpdate(_:)`.

**Verify this by test**, not by inspection: open a fixture, then assert a freshly built menu contains it. A test that only checks the menu at launch passes against a permanently stale menu.

- [ ] **Step 7: Verify**

```bash
swift build -Xswiftc -strict-concurrency=complete 2>&1 | grep -E "warning:|error:"
swift test 2>&1 | grep -E "Test run with|signal code|error:"
```

- [ ] **Step 8: Mutation-verify**

Remove the `RecentDocuments.note` call; `openingNotesARecentDocument` must fail. Restore. Change Open's `keyEquivalent` to `""`; `fileMenuHasOpen` must fail. Restore.

- [ ] **Step 9: Verify by hand and record it**

With the app built and registered, double-click a `.snitt` in the Finder and confirm an editor opens. Then quit, double-click again with the app **not running**, and confirm it launches and opens the document — cold-launch open goes through a different path (`application(_:open:)` arriving before or after `applicationDidFinishLaunching`) and is a classic source of "works only when already running." Report both.

- [ ] **Step 10: Commit**

```bash
git add Sources/SnittApp/RecentDocuments.swift Sources/SnittApp/AppShell.swift \
        Sources/SnittApp/main.swift Sources/SnittApp/DocumentOpener.swift Tests/SnittAppTests/
git commit -m "feat(shell): open .snitt documents from the menu, recents, and the Finder"
```

---

## Task 5: The Settings window

**Files:**
- Create: `Sources/SnittApp/SettingsWindowController.swift`
- Modify: `Sources/SnittApp/main.swift` (`showSettings`), `Sources/SnittApp/StatusItemController.swift`
- Test: `Tests/SnittAppTests/SettingsWindowTests.swift`

**Interfaces:**
- Consumes: `AgentSettings`, `EventLoggingSettings`, `UpdateSettings`, and the crash-report setting (all `load(_:)` / `save(to:)`, defaulting to off).
- Produces: `@MainActor final class SettingsWindowController` with `static func show()`.

**Why this task exists:** four settings accumulated as status-item toggles across M2b–M5b. §4.14 requires a Settings window on ⌘,.

**Do not remove the status-item toggles.** They are the fast path, and one of them (crash reports) carries a comment noting it is currently the *only* way to reach that setting. Both surfaces must read and write the same `UserDefaults` keys, so a change in one is visible in the other.

- [ ] **Step 1: Write the failing test**

```swift
@Suite(.serialized)
struct SettingsWindowTests {
    init() { _ = NSApplication.shared }

    @Test("Every setting defaults to off in a clean domain")
    func settingsDefaultOff() throws {
        let suiteName = "com.snitt.test.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AgentSettings.load(defaults).agentRecordingEnabled == false)
        #expect(EventLoggingSettings.load(defaults).enabled == false)
        #expect(UpdateSettings.load(defaults).automaticChecksEnabled == false)
    }

    @Test("A corrupt stored value reads as off, not on")
    func corruptValueReadsAsOff() throws {
        let suiteName = "com.snitt.test.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Absent and invalid are DIFFERENT states, and both are not-on.
        // This project has been bitten by silent coercion four times.
        defaults.set("yes please", forKey: "com.impressiver.snitt.eventLoggingEnabled")
        #expect(EventLoggingSettings.load(defaults).enabled == false)
    }

    @Test("The settings window and the status menu write the same keys")
    func bothSurfacesShareStorage() throws {
        let suiteName = "com.snitt.test.settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // A settings window with its own storage is two settings wearing one
        // name: the menu says off, the window says on, and the user cannot
        // tell which one the app obeys.
        EventLoggingSettings(enabled: true).save(to: defaults)
        #expect(EventLoggingSettings.load(defaults).enabled == true)
    }
}
```

- [ ] **Step 2: Run and watch fail** (the third test fails only once the window exists; the first two may pass already — that is fine, they pin the defaults the window must not break).

- [ ] **Step 3: Write `SettingsWindowController`**

```swift
import AppKit

/// The Settings window (§4.14, ⌘,).
///
/// Consolidates four settings that accumulated as status-item toggles across
/// M2b–M5b. The status-item toggles STAY — they are the fast path — so both
/// surfaces read and write the same `UserDefaults` keys through the same
/// settings types. A settings window with its own storage would be two
/// settings wearing one name.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private static var shared: SettingsWindowController?

    private let window: NSWindow
    private let updater: UpdaterController

    static func show(updater: UpdaterController) {
        // A second ⌘, focuses the existing window rather than opening a
        // second one — two Settings windows can disagree on screen.
        if let existing = shared {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = SettingsWindowController(updater: updater)
        shared = controller
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(updater: UpdaterController) {
        self.updater = updater
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                          styleMask: [.titled, .closable],
                          backing: .buffered,
                          defer: false)
        window.title = "Settings"
        window.center()
        super.init()
        window.delegate = self
        window.contentView = makeContentView()
    }

    private func makeContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(checkbox(
            title: "Allow agent recording",
            isOn: AgentSettings.load().agentRecordingEnabled,
            action: #selector(toggleAgentRecording(_:))))

        stack.addArrangedSubview(checkbox(
            title: "Log input events",
            isOn: EventLoggingSettings.load().enabled,
            action: #selector(toggleEventLogging(_:))))

        stack.addArrangedSubview(checkbox(
            title: "Check for updates automatically",
            isOn: UpdateSettings.load().automaticChecksEnabled,
            action: #selector(toggleAutomaticUpdates(_:))))

        stack.addArrangedSubview(checkbox(
            title: "Include crash reports in diagnostics",
            isOn: CrashReportSettings.load().enabled,
            action: #selector(toggleCrashReports(_:))))

        return stack
    }

    private func checkbox(title: String, isOn: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = isOn ? .on : .off
        return button
    }

    @objc private func toggleAgentRecording(_ sender: NSButton) {
        var settings = AgentSettings.load()
        settings.agentRecordingEnabled = (sender.state == .on)
        settings.save()
    }

    @objc private func toggleEventLogging(_ sender: NSButton) {
        EventLoggingSettings(enabled: sender.state == .on).save()
    }

    @objc private func toggleAutomaticUpdates(_ sender: NSButton) {
        // Through UpdaterController, NOT straight to UserDefaults. M5b's R22
        // caught exactly this: a value stored but never forwarded to Sparkle's
        // own `automaticallyChecksForUpdates`, so the setting read back
        // correctly and changed nothing.
        updater.setAutomaticChecksEnabled(sender.state == .on)
    }

    @objc private func toggleCrashReports(_ sender: NSButton) {
        CrashReportSettings(enabled: sender.state == .on).save()
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}
```

**Check the real names before writing this.** `CrashReportSettings` comes from the in-flight crash-reports branch and `UpdaterController.setAutomaticChecksEnabled` from M5b — read both files and use whatever they actually declare. Do not add a shim to make this code compile as written; correct the code to match the codebase.

- [ ] **Step 4: Replace the `showSettings` stub**

```swift
    @objc func showSettings(_ sender: Any?) {
        // `updaterController` is the AppDelegate's existing property (it is
        // constructed at line 17 of main.swift). The Settings window routes
        // the update toggle through it rather than writing UserDefaults
        // directly — see Task 5 Step 3.
        SettingsWindowController.show(updater: updaterController)
    }
```

- [ ] **Step 5: Verify**

```bash
swift build -Xswiftc -strict-concurrency=complete 2>&1 | grep -E "warning:|error:"
swift test 2>&1 | grep -E "Test run with|signal code|error:"
```

Then confirm the real domain is untouched:

```bash
stat -f "%m" ~/Library/Preferences/com.impressiver.snitt.plist
```

Same value before and after a full run.

- [ ] **Step 6: Mutation-verify**

Give `SettingsWindowController` its own `UserDefaults(suiteName:)` instead of the shared store. `bothSurfacesShareStorage` must fail. Restore.

- [ ] **Step 7: Verify by hand**

Toggle each setting in the window, close it, open the status menu, and confirm the checkmarks agree. Report the result.

- [ ] **Step 8: Commit**

```bash
git add Sources/SnittApp/SettingsWindowController.swift Sources/SnittApp/main.swift \
        Tests/SnittAppTests/SettingsWindowTests.swift
git commit -m "feat(shell): a Settings window on Command-comma"
```

---

## Task 6: Multiple document windows and the Window menu

**Files:**
- Modify: `Sources/SnittApp/EditorWindowController.swift`, `Sources/SnittApp/AppShell.swift`
- Test: `Tests/SnittAppTests/DocumentOpenerTests.swift`

**Interfaces:**
- Consumes: `DocumentOpener` (Task 2), `AppShell` (Task 1).

- [ ] **Step 1: Write the failing test**

```swift
@Test("Two different bundles open two independent windows")
func twoBundlesOpenTwoWindows() async throws {
    let a = try makeFixtureBundle()
    let b = try makeFixtureBundle()
    defer {
        try? FileManager.default.removeItem(at: a)
        try? FileManager.default.removeItem(at: b)
    }

    let before = EditorWindowController.openWindowCount
    let first = try await DocumentOpener.open(bundleURL: a)
    let second = try await DocumentOpener.open(bundleURL: b)
    defer { first.close(); second.close() }

    #expect(EditorWindowController.openWindowCount == before + 2)
    #expect(first.window !== second.window)
}

@Test("Opening the same bundle twice focuses the existing window instead of duplicating it")
func sameBundleReusesItsWindow() async throws {
    let url = try makeFixtureBundle()
    defer { try? FileManager.default.removeItem(at: url) }

    let first = try await DocumentOpener.open(bundleURL: url)
    defer { first.close() }
    let before = EditorWindowController.openWindowCount
    let second = try await DocumentOpener.open(bundleURL: url)

    // Two windows on one document means two EDLs over one bundle, and
    // whichever saves last wins — a data-loss shape, not a cosmetic one.
    #expect(EditorWindowController.openWindowCount == before)
    #expect(first.window === second.window)
}
```

- [ ] **Step 2: Run and watch the second fail** (the first may already pass — `EditorWindowController` already tracks a count and an `open` array).

- [ ] **Step 3: Implement identity-based reuse**

Add a stored `bundleURL` to `EditorWindowController` and expose a lookup:

```swift
    /// The document this window edits. Standardized on the way in so two
    /// spellings of one path cannot open two windows onto one document —
    /// on macOS `/tmp` is a symlink to `/private/tmp`, so a raw string
    /// comparison would let exactly that through.
    public let bundleURL: URL

    static func existing(for url: URL) -> EditorWindowController? {
        let wanted = url.standardizedFileURL.resolvingSymlinksInPath()
        return open.first { $0.bundleURL == wanted }
    }
```

Then check **before** building anything, in `DocumentOpener.open(bundle:)`:

```swift
    static func open(bundle: SnittBundle) async throws -> EditorWindowController {
        // Before the composition, not after: building it first wastes the
        // work and can leave a half-built preview behind on the reuse path.
        if let existing = EditorWindowController.existing(for: bundle.url) {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }
        // ... existing build path ...
    }
```

Two windows on one document means two EDLs over one bundle and whichever saves last wins — data loss, not a cosmetic duplicate.

- [ ] **Step 4: Add the Window menu's document list**

Append open editor windows to the Window menu, and keep it current with `NSMenuDelegate.menuNeedsUpdate(_:)` as in Task 4.

- [ ] **Step 5: Verify**

```bash
swift build -Xswiftc -strict-concurrency=complete 2>&1 | grep -E "warning:|error:"
swift test 2>&1 | grep -E "Test run with|signal code|error:"
```

- [ ] **Step 6: Mutation-verify**

Remove the identity check; `sameBundleReusesItsWindow` must fail. Then compare raw `url` strings instead of standardized ones and open the same bundle via `/tmp/...` and `/private/tmp/...` — confirm the test catches it. If it does not, the test is checking a property adjacent to the one that matters.

- [ ] **Step 7: Commit**

```bash
git add Sources/SnittApp/EditorWindowController.swift Sources/SnittApp/AppShell.swift \
        Tests/SnittAppTests/DocumentOpenerTests.swift
git commit -m "feat(shell): one window per document, and a Window menu"
```

---

## Definition of Done

- [ ] `NSApp.activationPolicy() == .regular` permanently; the promote/demote dance is gone.
- [ ] A main menu with App, File, Edit, Window, Help; ⌘, ⌘O ⌘W ⌘Q all bound.
- [ ] A `.snitt` bundle opens from File ▸ Open, Open Recent, and a Finder double-click — **including a cold launch**.
- [ ] The Finder shows a `.snitt` as one document, not a folder.
- [ ] A Settings window carrying all four settings, sharing storage with the status-item toggles.
- [ ] One window per document; the same bundle twice focuses rather than duplicates.
- [ ] **§4.11 verified by hand:** the hotkey records with no window opening, and the picker still appears every time.
- [ ] The status item still works, including the kill switch.
- [ ] Full suite green, twice, with the trustworthy summary line; strict-concurrency build clean.
- [ ] The real preference domain's mtime is unchanged across a full run.

## Deliberately not in scope

- **Adopting `NSDocument`.** §4.14 asks for an app that opens its documents, not for the document architecture. `NSDocument` would bring autosave, versions, and a coupling to the editor's EDL model that no requirement asks for. `NSDocumentController` is used only for its recents list.
- **A SwiftUI `Settings` scene.** §4.7 names SwiftUI for the shell, but the app has an AppKit `main.swift` entry point and no `App` conformance; converting the entry point is a larger change than this milestone. The window is AppKit for consistency with `EditorWindowController`. Note this as a deviation from §4.7 in the final report.
- **Overlay rendering** — M7, conditional on M6.
