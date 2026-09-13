// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import SnittExport
import Foundation
import SnittCapture
import SnittDocument
import UniformTypeIdentifiers

/// Menu-bar app entry point.
///
/// A regular app (§4.14, D45): Dock icon and main menu always present, and
/// still no window at launch. §4.11 requires that recording start from a
/// keystroke without a window ever opening — that is about what the hotkey
/// does, not about whether the app has a shell.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // §4.14: File ▸ Open / Open Recent / Finder double-click all funnel into
    // `openURLs`, and a failure there is surfaced with this logger — the
    // project's factory (`SnittLog.logger`), never a hand-rolled `Logger`,
    // or the failure becomes invisible to `snitt diagnostics export`.
    private static let log = SnittLog.logger(.automation, target: "SnittApp")

    private let statusItem = StatusItemController()
    /// The floating recording HUD (§4.11). Lazy: constructing an `NSPanel`
    /// at delegate-init time runs before `applicationDidFinishLaunching` and
    /// before any screen geometry is worth asking about.
    private lazy var recordingHUD: RecordingHUDPanel = makeRecordingHUD()
    /// When the current recording began, kept so resuming can rebuild a
    /// `.recording` state rather than inventing a new start time.
    private var recordingStartedAt: Date?
    /// Owns both real hotkey registrations (D55) — see `HotkeyRegistrar`'s
    /// own doc comment for why persistence and re-registration must move
    /// together. Optional for the same reason `coordinator` below is: real
    /// construction (closures capturing `self`) happens in
    /// `applicationDidFinishLaunching`, never at `AppDelegate.init` — a
    /// test constructing a bare `AppDelegate()` must not touch real Carbon
    /// hotkey registration as a side effect.
    private var hotkeyRegistrar: HotkeyRegistrar?
    private var coordinator: RecordingCoordinator?
    private var automationHost: AutomationHost?
    private let updaterController = UpdaterController(settings: UpdateSettings.load())

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.install()

        // Started here, once, at real launch — never from a unit test's
        // construction of UpdaterController, which would touch Sparkle's
        // configuration validation against a bundle it was never set up for.
        updaterController.start()
        statusItem.onCheckForUpdates = { [weak self] in
            self?.updaterController.checkForUpdates()
        }

        statusItem.onToggleAutomaticUpdateChecks = { [weak self] enabled in
            guard let self else { return }
            var settings = UpdateSettings.load()
            settings.automaticChecksEnabled = enabled
            settings.save()
            self.updaterController.automaticChecksEnabled = enabled
        }

        // Where recordings are saved (D56/M5d's deferred output-location
        // item, pulled forward for M5f). No value is captured here: the
        // coordinator reads `OutputDirectorySettings.load()` itself, FRESH,
        // on every recording — see that type's own doc comment for why the
        // default is `~/Documents/Snitt`, not `~/Desktop`, and
        // `RecordingCoordinator`'s `outputDirectorySettings` doc comment for
        // why it is read at record time rather than cached here at launch.
        let coordinator = RecordingCoordinator(
            pickerResolver: PickerTargetResolver(),
            cachedResolverFactory: { CachedTargetResolver(reference: $0) },
            store: TargetStore(fileURL: TargetStore.defaultURL())
        )
        self.coordinator = coordinator

        var agentSettings = AgentSettings.load()
        statusItem.onToggleAgentRecording = { enabled in
            agentSettings.agentRecordingEnabled = enabled
            agentSettings.save()
        }

        statusItem.onToggleEventLogging = { enabled in
            // Routed through EventLoggingToggle so the status item and the
            // Settings window run exactly the same §4.10 ladder — see its
            // doc comment for why a second copy of this logic is a defect,
            // not a convenience. `apply` PERSISTS the state actually reached,
            // which is `false` (not `enabled`) whenever the pre-explain is
            // declined or the grant is unavailable — and the menu reads that
            // store when it is next built, so a refused grant leaves the
            // checkmark off without anything having to mirror the result.
            _ = EventLoggingToggle.apply(enabled)
        }

        statusItem.onToggleMicrophone = { enabled in
            // Same §4.10 ladder, same reasoning as `onToggleEventLogging`
            // just above — see `MicrophoneToggle`'s doc comment.
            _ = MicrophoneToggle.apply(enabled)
        }

        // §5.3 requires a visible indicator for the WHOLE duration of a
        // recording, agent-initiated ones included. The indicator is driven by
        // whoever calls the coordinator, and until this sink existed only
        // `handleHotkey()` did — so an agent recording ran with the menu bar
        // showing idle and the kill switch looking like it had nothing to stop.
        let host = AutomationHost(
            coordinator: coordinator,
            settings: { AgentSettings.load() },
            onRecordingState: { [weak self] state in self?.statusItem.update(state) })
        host.start()
        automationHost = host

        // D55: combinations are now customizable via the Settings window, so
        // launch registers whatever `HotkeySettings` has stored — today's
        // ⌥⌘5 / ⌥⌘M for a user who has never changed either (see
        // `HotkeySettings.load`'s own doc comment). `HotkeyRegistrar` is the
        // one place persistence and live registration move together; see
        // its own doc comment for why that matters (M5b's R22 defect, in a
        // new place, is exactly what a stored-but-unregistered combination
        // would be).
        let registrar = HotkeyRegistrar(
            onRecord: { [weak self] in self?.handleHotkey() },
            onMarker: { [weak self] in self?.handleMarkerHotkey() })
        registrar.start { [weak self] action, combination in
            self?.reportHotkeyRegistrationFailure(action, combination)
        }
        hotkeyRegistrar = registrar

        // §5.3's kill switch: clicking the menu-bar item does the same thing as
        // the hotkey, so a recording can always be stopped by mouse alone —
        // which matters when the hotkey is what someone is demonstrating.
        statusItem.onClick = { [weak self] in
            self?.handleHotkey()
        }

        // Quitting stops an in-flight recording first. Terminating mid-capture
        // would leave a bundle whose capture.mov is playable (fragments are
        // flushed as they are written) but whose sidecar files were never
        // produced — a half-written document rather than a short one.
        statusItem.onQuit = { [weak self] in
            guard let self, let coordinator = self.coordinator else {
                NSApp.terminate(nil)
                return
            }
            Task { @MainActor in
                _ = await coordinator.stopIfRecording()
                NSApp.terminate(nil)
            }
        }

        // A submenu built once at install time (AppShell.buildMainMenu) is
        // permanently stale — it never reflects a document opened after
        // launch. Becoming its delegate is what makes `menuNeedsUpdate(_:)`
        // fire each time the user actually opens the submenu.
        if let recentMenu = NSApp.mainMenu?
            .item(withTitle: "File")?.submenu?
            .item(withTitle: "Open Recent")?.submenu {
            recentMenu.delegate = self
        }

        offerToOpenADocumentIfLaunchedBare()
    }

    /// Launching Snitt on its own opens the Open dialog; every other way in
    /// does not. See `LaunchOpenPrompt` for which cases those are and why.
    ///
    /// **Deferred by a runloop pass, deliberately.** `application(_:open:)`
    /// can arrive either side of `applicationDidFinishLaunching` on a cold
    /// launch — its own doc comment says so — so asking "was a document
    /// opened" right here would sometimes be asking before the answer exists,
    /// and double-clicking a `.snitt` would occasionally get a panel over the
    /// document it just opened. One hop is enough: by the next pass the open
    /// event has been delivered, a recording started by the hotkey has set
    /// the coordinator's state, and any editor window is on screen.
    private func offerToOpenADocumentIfLaunchedBare() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let recording = await self.coordinator?.isRecording ?? false
                // The app's OWN windows, not `NSApp.windows`.
                //
                // `NSApp.windows` includes the `NSStatusBarWindow` the
                // menu-bar item lives in — which exists from the moment
                // `statusItem.install()` runs, i.e. always, by the time this
                // asks. So `hasVisibleWindows` was true on every launch and
                // the panel never appeared: the decision was right and its
                // input was wrong, which is the harder half to see.
                //
                // An editor window is what "something is already open" means
                // here, and `openEditors` is the registry that knows.
                let openDocuments = EditorWindowController.openEditors.contains {
                    $0.window.isVisible
                }
                let decision = LaunchOpenPrompt.decide(
                    openingDocument: !self.openTasks.isEmpty,
                    hasVisibleWindows: openDocuments,
                    isRecording: recording)
                guard decision == .prompt else { return }
                // Bring the app forward first. A launch from Spotlight or the
                // Dock usually activates it anyway, but a modal panel run by
                // an app that is not frontmost opens behind whatever is —
                // which looks exactly like the panel never appearing.
                NSApp.activate(ignoringOtherApps: true)
                self.openDocument(nil)
            }
        }
    }

    private func handleHotkey() {
        guard let coordinator else { return }
        // §4.13: auto-focus is the default, not a rule. Holding Shift while
        // pressing the hotkey records the target where it sits.
        let suppress = NSEvent.modifierFlags.contains(.shift)
        Task { @MainActor in
            // The interactive half of §4.10's permission ladder lives HERE, not
            // in the coordinator: this is the only path with a human in front
            // of it. An agent's `record start` shares the coordinator, and a
            // modal raised there would land on someone's screen and block the
            // socket until it was clicked.
            //
            // Only for a press that would START something — stopping needs no
            // grant and must never raise a sheet.
            if await !coordinator.isRecording, !ensureScreenRecordingGrant() { return }

            let outcome = await coordinator.toggle(suppressFocus: suppress)
            switch outcome {
            case .started(_, let usedCache):
                recordingStartedAt = Date()
                setRecordingState(.recording(startedAt: recordingStartedAt ?? Date()))
                // A human recording supersedes any agent session the registry
                // still remembers — see AutomationHost.stop().
                await automationHost?.clearAgentSession()
                // The recurring macOS prompt is caused by the cached path only, so
                // explain it at its first actual occurrence — not on the picker path.
                if usedCache { ConsentExplainer.showIfNeeded() }
            case .stopped(let url, let copied):
                recordingStartedAt = nil
                setRecordingState(.idle)
                // This press may have been the kill switch ending an AGENT
                // recording. Clearing the registry here is what stops a later
                // `record stop <id>` from believing that session is still live.
                await automationHost?.clearAgentSession()
                if !copied {
                    notify("Recording saved to \(url.lastPathComponent), but it could "
                         + "not be copied to the clipboard.")
                }
            case .cancelled:
                recordingStartedAt = nil
                setRecordingState(.idle)
            case .failed(let message, _):
                recordingStartedAt = nil
                setRecordingState(.idle)
                // A press that stopped an agent recording but failed to
                // FINALIZE it still ended that recording — `stopRecording()`
                // clears `active` before it can throw. Without this the
                // registry keeps claiming a session is live.
                await automationHost?.clearAgentSession()
                notify(message)
            case .ignored:
                // A press landed mid-transition. Deliberately silent: the user
                // pressed twice quickly and the first press is still working.
                break
            }
        }
    }

    /// Runs §4.10's ladder for a person: explain, ask, and follow up correctly.
    ///
    /// Returns whether recording may proceed.
    ///
    /// The follow-up is where the first run used to go wrong.
    /// `CGRequestScreenCaptureAccess()` returns `false` WHILE the user is
    /// granting in the dialog it just raised (spike S5), so showing "Screen
    /// Recording is turned off for Snitt. macOS only asks once." on that
    /// `false` put a contradiction on top of the live dialog. It is shown only
    /// once Snitt has asked BEFORE — which is the state in which macOS really
    /// does refuse to ask again.
    private func ensureScreenRecordingGrant() -> Bool {
        if ScreenRecordingAccess.isGranted() { return true }
        // Nothing is requested at launch; this is first use (§4.10).
        guard PermissionOnboarding.preExplain(.screenRecording) else { return false }

        let askedBefore = PermissionOnboarding.hasRequested(.screenRecording)
        PermissionOnboarding.markRequested(.screenRecording)
        if ScreenRecordingAccess.ensureGranted() { return true }

        switch PermissionOnboarding.followUp(deniedHavingAskedBefore: askedBefore) {
        case .awaitingRelaunch:
            // Deliberately silent. macOS's own dialog is on screen and is the
            // only thing the user should be reading; the grant takes effect on
            // the next launch.
            break
        case .alreadyDenied:
            PermissionOnboarding.showAlreadyDenied(.screenRecording)
        }
        return false
    }

    /// ⌥⌘M drops a marker into whatever is recording — the human half of §4.12.
    ///
    /// Deliberately silent when nothing is recording: a marker hotkey that
    /// interrupts with an alert would be worse than one that does nothing —
    /// the user already knows there was nothing to mark.
    private func handleMarkerHotkey() {
        guard let coordinator else { return }
        Task { await coordinator.markCurrentRecording(label: nil) }
    }

    /// How a plain informational message reaches the person at the screen.
    ///
    /// A seam, and a load-bearing one. The default raises a real
    /// `NSAlert.runModal()`, which blocks the main thread until somebody
    /// clicks OK. A TEST that reaches this path does not merely hang itself —
    /// it hangs the entire run, because a modal run loop starves the MainActor
    /// every other test needs, **including any watchdog meant to catch a hang**.
    /// The bounded test gates added the same day are useless against it for
    /// exactly that reason: their polling loop never gets scheduled either.
    ///
    /// That is not hypothetical. `DockReopenTests` calls the real
    /// `applicationShouldHandleReopen`, and its "most recent document" comes
    /// from `NSDocumentController.recentDocumentURLs` — machine-global state
    /// that two other suites clear in their own `defer`s. Lose that race and
    /// the reopen path finds no recents, raises this alert, and the run stops
    /// dead with no output. Observed 2026-09-09, on screen.
    ///
    /// So tests replace this. Not to observe the message — to make raising a
    /// modal impossible rather than unlikely.
    @MainActor static var presentMessage: (String) -> Void = { message in
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// The single place a recording state reaches the UI.
    ///
    /// Both indicators — the menu-bar item and the HUD — are updated here and
    /// nowhere else. Two call sites is how they end up disagreeing: the menu
    /// bar says Paused while the HUD says Recording, and neither is obviously
    /// the stale one.
    func setRecordingState(_ state: RecordingState) {
        statusItem.update(state)
        recordingHUD.update(state: state)
    }

    private func makeRecordingHUD() -> RecordingHUDPanel {
        // The HUD names the keys the user actually has bound, read from the
        // same `HotkeySettings` the recorder buttons in Settings write to.
        // Pause has no hotkey yet, so it names none rather than pointing at a
        // key that does nothing.
        let settings = HotkeySettings.load()
        let hud = RecordingHUDPanel(shortcuts: .init(
            mark: settings[.marker].displayString,
            pause: nil,
            stop: settings[.record].displayString))
        hud.onMark = { [weak self] in
            Task { @MainActor in
                guard let coordinator = self?.coordinator else { return }
                _ = await coordinator.markCurrentRecording(label: nil)
            }
        }
        hud.onTogglePause = { [weak self] in
            Task { @MainActor in
                guard let self, let coordinator = self.coordinator,
                      let startedAt = self.recordingStartedAt else { return }
                // The state is read back off the indicator rather than kept a
                // second time here, so the button always toggles what the user
                // can actually see.
                if case .paused = self.statusItem.state {
                    if await coordinator.setPaused(false) {
                        self.setRecordingState(.recording(startedAt: startedAt))
                    }
                } else if await coordinator.setPaused(true) {
                    self.setRecordingState(.paused(startedAt: startedAt, pausedSeconds: 0))
                }
            }
        }
        // The same path as the menu-bar kill switch, never a second stop.
        hud.onStop = { [weak self] in self?.statusItem.onClick?() }
        return hud
    }

    private func notify(_ message: String) {
        AppDelegate.presentMessage(message)
    }

    /// A hotkey combination another app already owns must say so (D55) —
    /// this is the exact alert `main.swift` always raised for this failure,
    /// extracted so `HotkeyRegistrar.start()` at launch and the Settings
    /// window's key recorder (via `SettingsWindowController.show`'s
    /// `hotkeyRegistrar`) report it identically regardless of when the
    /// conflict is discovered. Recording stays reachable from the menu bar
    /// either way — §5.3's kill switch never depended on either hotkey.
    private func reportHotkeyRegistrationFailure(_ action: HotkeyAction, _ combination: HotkeyCombination) {
        notify("Snitt could not register \(combination.displayString) for the \(action.label) — "
             + "another app may be using it. You can still start and stop recording, and drop "
             + "markers, from the menu bar.")
    }

    @objc func showSettings(_ sender: Any?) {
        // Routes the update toggle through `updaterController` rather than
        // writing UserDefaults directly — see SettingsWindowController's
        // doc comment. `onChange` re-reads all five checkbox settings back
        // into the status item's own cached properties, so a change made in
        // the window shows up as the correct checkmark the next time the
        // status menu is opened, rather than only after the next launch.
        //
        // `hotkeyRegistrar` is optional only because a test can construct a
        // bare `AppDelegate()` without ever running
        // `applicationDidFinishLaunching` (see that property's own doc
        // comment) — in the shipping app, launch always runs first, so this
        // is never nil when a person can actually click Settings.
        guard let hotkeyRegistrar else {
            SettingsWindowController.show(updater: updaterController)
            return
        }
        SettingsWindowController.show(updater: updaterController,
                                      hotkeyRegistrar: hotkeyRegistrar)
    }

    // MARK: - §4.14: File ▸ Open, Open Recent, Finder double-click

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType("com.impressiver.snitt.recording")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        // A .snitt is a package: without this the panel descends into it
        // instead of letting it be selected — the same class of bug as
        // Task 3's `com.apple.package` conformance, on a different surface.
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

    /// File ▸ Export… (⌘E), Task 8. `EditorWindowController` is not an
    /// `NSWindowController` and is never inserted into the responder chain,
    /// so this menu item's nil target resolves here (AppKit's fallback
    /// after the responder chain, mirroring `openDocument` above) rather
    /// than to a specific editor directly. The KEY window, not
    /// `openEditors.first`, is what picks which of several open documents
    /// this export is for — with more than one editor window open, "the
    /// front one" is the only reading a user would expect from a plain
    /// ⌘E.
    ///
    /// Silently does nothing with no editor key — a keyboard shortcut
    /// pressed with no document open has nothing to export, and Snitt's
    /// menu items generally reflect this by staying live rather than
    /// managing per-item enabled state (see `Close`, `Undo`/`Redo` above).
    /// Playback actions, all resolved the same way `exportDocument` is: the
    /// editor is not in the responder chain, so these land on the app delegate
    /// and are forwarded to whichever editor owns the key window.
    ///
    /// Silent when no editor is focused. These are bound to BARE keys — Space,
    /// Home, ⌥arrows — so a press with the Settings window frontmost, or no
    /// window at all, must do nothing rather than reach for a document that
    /// is not there.
    private var focusedEditor: EditorWindowController? {
        EditorWindowController.openEditors.first { $0.window == NSApp.keyWindow }
    }

    @objc func togglePlayback(_ sender: Any?) { focusedEditor?.togglePlayback() }
    @objc func rewindToStart(_ sender: Any?) { focusedEditor?.rewindToStart() }
    @objc func goToPreviousMark(_ sender: Any?) { focusedEditor?.goToPreviousMark() }
    @objc func goToNextMark(_ sender: Any?) { focusedEditor?.goToNextMark() }

    /// Playback ▸ Show Clicks, for the document in front.
    ///
    /// Per document, because the flag lives in that document's `edit.json`: a
    /// screen-capture demo wants its clicks shown and a recording of somebody's
    /// face does not, and the answer travels with the bundle. Resolved from the
    /// KEY window — the same question `exportDocument` asks, so the menu cannot
    /// act on a document that is not the one you are looking at.
    @objc func toggleShowClicks(_ sender: Any?) {
        guard let editor = focusedEditor else { return }
        editor.setShowClicks(!editor.showsClicks)
    }

    /// Help ▸ Keyboard Shortcuts, rendered from the registry that installed
    /// the keys — so it cannot describe a binding that does not exist.
    @objc func showKeyboardShortcuts(_ sender: Any?) {
        AppDelegate.presentMessage(KeyboardShortcutRegistry.helpText)
    }

    /// File ▸ Share… — hands the exported recording to macOS's share sheet.
    @objc func shareDocument(_ sender: Any?) {
        focusedEditor?.share()
    }

    /// File ▸ Export for ▸ <destination>.
    ///
    /// Resolved from the sender's `representedObject` rather than its title,
    /// so renaming a menu entry cannot silently retarget the export.
    @objc func exportForDestination(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? String,
              let destination = ExportDestination.named(id),
              let editor = focusedEditor else { return }
        editor.exportFor(destination)
    }

    @objc func exportDocument(_ sender: Any?) {
        guard let editor = EditorWindowController.openEditors.first(where: {
            $0.window == NSApp.keyWindow
        }) else { return }
        editor.presentExportPanel()
    }

    /// Edit ▸ Cut Selection (Delete/Backspace), Task 5 (D56). Same nil-target
    /// resolution as `exportDocument` just above, for the same reason: this
    /// menu item's target is `nil`, `EditorWindowController` is never in the
    /// responder chain, and the KEY window picks which open editor a bare
    /// keypress applies to.
    ///
    /// Silently does nothing with no editor key, same as `exportDocument` —
    /// but UNLIKE that one, this action is also gated by
    /// `validateMenuItem(_:)` below, so in practice the menu item (and the
    /// bare delete key it's bound to) is disabled whenever this guard would
    /// fail, rather than relying on a user never triggering a no-op.
    @objc func cutTimelineSelection(_ sender: Any?) {
        guard let editor = EditorWindowController.openEditors.first(where: {
            $0.window == NSApp.keyWindow
        }) else { return }
        editor.cutTimelineSelection()
    }

    /// Finder double-click, `open(1)`, and drag-onto-Dock all arrive here.
    /// Can arrive before OR after `applicationDidFinishLaunching` on a cold
    /// launch — this must not depend on anything that method sets up.
    func application(_ application: NSApplication, open urls: [URL]) {
        openURLs(urls)
    }

    /// The Dock icon (or ⌘-Tab, or Launch Services) asking to be brought
    /// back with no window already visible. Under Task 1's permanent
    /// `.regular` policy the Dock icon is present even after the last
    /// editor window closes — without this, clicking it does nothing.
    ///
    /// §4.11 note: this fires only from an explicit reopen gesture with
    /// `flag == false`. It never runs at launch (`hasVisibleWindows` is not
    /// consulted there) and it does not fight the no-window-at-launch
    /// design the hotkey depends on — it only answers a click the user
    /// deliberately made.
    ///
    /// The decision (reopen the most recent document, or explain there is
    /// none) is delegated to `DockReopen.handle` so it can be tested
    /// without a real `NSAlert` or a real bundle on disk; `openURLs` is the
    /// exact same path File ▸ Open / Open Recent / Finder double-click use,
    /// so an already-open window for that document is focused rather than
    /// duplicated.
    ///
    /// Returns `false` unconditionally when there were no visible windows:
    /// this method has already decided what to do, so AppKit's own default
    /// handling — which does nothing useful for a non-`NSDocument` app with
    /// no windows — should not also run.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        DockReopen.handle(
            recentURLs: RecentDocuments.urls(),
            open: { [weak self] url in self?.openURLs([url]) },
            explainNoRecents: { [weak self] in
                self?.notify("Snitt has no recent recordings to reopen. Use ⌥⌘5 to "
                            + "start one, or File ▸ Open to pick a file.")
            }
        )
        return false
    }

    /// In-flight `openURLs` work, so a test can AWAIT an open instead of
    /// polling with a deadline (whole-branch review F5): on a timeout the
    /// escaped `Task` opens a real window inside another suite's
    /// before/after snapshot — a flake that propagates from a flake. Each
    /// task removes its own entry, so this does not grow with use.
    private var openTasks: [UUID: Task<Void, Never>] = [:]

    /// Awaits every in-flight `openURLs` `Task`, including any started while
    /// awaiting an earlier one.
    func waitForOpensForTesting() async {
        while !openTasks.isEmpty {
            let running = openTasks.values
            for task in running { await task.value }
        }
    }

    // MARK: - Termination (whole-branch review F9)

    /// What to tell AppKit once pending saves are flushed.
    ///
    /// A stored closure rather than a direct call so a test can pin the
    /// termination decision without poking
    /// `reply(toApplicationShouldTerminate:)` outside a real termination
    /// sequence — the one call in this file that could take the test
    /// process down with it.
    var replyToTerminate: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }

    /// The in-flight flush, for tests to await.
    private var terminationFlush: Task<Void, Never>?

    func waitForTerminationFlushForTesting() async {
        await terminationFlush?.value
    }

    /// ⌘Q — or the status item's Quit — pressed immediately after a trim
    /// used to terminate before that trim's autosave finished, silently
    /// losing it. Autosave is an unstructured `Task`; nothing waited for it.
    /// With F1's apply-gate in place this was the last remaining path by
    /// which a completed edit could vanish.
    ///
    /// `.terminateNow` when there is nothing outstanding, so the common quit
    /// is unchanged and never waits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard EditorWindowController.hasPendingSaves else { return .terminateNow }
        terminationFlush = Task { @MainActor [weak self] in
            await EditorWindowController.flushPendingSaves()
            self?.replyToTerminate(true)
        }
        return .terminateLater
    }

    private func openURLs(_ urls: [URL]) {
        for url in urls {
            let id = UUID()
            openTasks[id] = Task { @MainActor [weak self] in
                defer { self?.openTasks[id] = nil }
                do {
                    _ = try await DocumentOpener.open(bundleURL: url)
                } catch {
                    // Privacy: the bundle filename comes from the git branch
                    // (BundleNaming), so it can name a customer or an
                    // unreleased feature. Domain/code/description only —
                    // never a path, never `String(describing:)` on the error.
                    let ns = error as NSError
                    Self.log.error("Could not open the document: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .public)")
                    self?.presentOpenFailure(error)
                }
            }
        }
    }

    /// A double-click that does nothing is the failure users report as "the
    /// app is broken" — this is what turns a swallowed error into something
    /// the person in front of the screen can see.
    private func presentOpenFailure(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Snitt could not open this recording."
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Task 5 (D56): "a user with nothing selected must not be offered an
/// action that does nothing." Every other menu item in `AppShell` stays
/// live unconditionally (see `exportDocument`'s own doc comment on that
/// convention) — this is the one deliberate exception, and it exists for a
/// second reason beyond politeness: the Cut Selection item is bound to a
/// BARE delete/backspace key (`AppShell.editMenuItem`), which AppKit's main
/// menu intercepts before an ordinary text field ever sees the keystroke.
/// Left permanently enabled, it would swallow every Backspace typed
/// anywhere in the app — the Export panel's filename field included —
/// whenever an editor window happened to be key. Disabling it whenever
/// there is nothing for it to do is what lets that Backspace fall through
/// to normal text editing instead.
extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Export needs a document to export. With no editor in front of it the
        // item did nothing when picked — `exportDocument(_:)` resolves its
        // editor from `NSApp.keyWindow` and returns early when there is none —
        // so the menu offered an action and then silently declined it, which
        // reads as a broken app rather than as "nothing is open".
        //
        // Note this asks for the KEY window's editor, the same question the
        // action itself asks. Enabling on "any editor exists" would re-create
        // the same silence whenever the frontmost window is Settings.
        // The checkmark IS the document's state — read from `edit.json` via
        // the focused editor, never tracked beside it. A menu item holding its
        // own copy is how a toggle ends up showing one thing while the export
        // does another.
        //
        // Disabled with no document in front, like Export: the action resolves
        // its editor from the key window and would otherwise do nothing when
        // picked, which reads as a broken app rather than as "nothing is open".
        if menuItem.action == #selector(toggleShowClicks(_:)) {
            let editor = EditorWindowController.openEditors.first { $0.window == NSApp.keyWindow }
            menuItem.state = (editor?.showsClicks ?? false) ? .on : .off
            return editor != nil
        }
        // Export, Export for, and Share all resolve their editor from the KEY
        // window and all do nothing without one. Grouped rather than repeated:
        // three copies of this rule is three places for one of them to drift
        // into offering an action it then silently declines.
        if menuItem.action == #selector(exportDocument(_:))
            || menuItem.action == #selector(exportForDestination(_:))
            || menuItem.action == #selector(shareDocument(_:)) {
            return EditorWindowController.openEditors.contains { $0.window == NSApp.keyWindow }
        }
        guard menuItem.action == #selector(cutTimelineSelection(_:)) else { return true }
        // The title follows the highlight: one key, one item, two edits. A
        // menu permanently reading "Cut Selection" while Delete would restore
        // a fold describes the opposite of what it does.
        if let editor = EditorWindowController.openEditors.first(where: {
            $0.window == NSApp.keyWindow
        }) {
            menuItem.title = editor.deleteMenuTitle
        }
        return EditorWindowController.openEditors.first(where: {
            $0.window == NSApp.keyWindow
        })?.hasTimelineSelection ?? false
    }
}

extension AppDelegate: NSMenuDelegate {
    /// A submenu built once at launch never reflects a document opened
    /// afterwards. Rebuilding here — rather than trusting whatever items
    /// `AppShell.buildMainMenu()` populated it with at install time — is
    /// what keeps Open Recent live for the life of the app.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let fresh = RecentDocuments.buildMenu()
        menu.removeAllItems()
        for item in fresh.items {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }
}

let app = NSApplication.shared
AppShell.install(into: app)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
