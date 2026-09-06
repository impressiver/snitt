import AppKit
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
    private var hotkey: HotkeyMonitor?
    private var markerHotkey: HotkeyMonitor?
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

        statusItem.automaticUpdateChecksEnabled = UpdateSettings.load().automaticChecksEnabled
        statusItem.onToggleAutomaticUpdateChecks = { [weak self] enabled in
            guard let self else { return }
            var settings = UpdateSettings.load()
            settings.automaticChecksEnabled = enabled
            settings.save()
            self.updaterController.automaticChecksEnabled = enabled
            self.statusItem.automaticUpdateChecksEnabled = enabled
        }

        let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")

        let coordinator = RecordingCoordinator(
            pickerResolver: PickerTargetResolver(),
            cachedResolverFactory: { CachedTargetResolver(reference: $0) },
            store: TargetStore(fileURL: TargetStore.defaultURL()),
            outputDirectory: outputDirectory
        )
        self.coordinator = coordinator

        var agentSettings = AgentSettings.load()
        statusItem.agentRecordingEnabled = agentSettings.agentRecordingEnabled
        statusItem.onToggleAgentRecording = { [weak self] enabled in
            agentSettings.agentRecordingEnabled = enabled
            agentSettings.save()
            self?.statusItem.agentRecordingEnabled = enabled
        }

        statusItem.eventLoggingEnabled = EventLoggingSettings.load().enabled
        statusItem.onToggleEventLogging = { [weak self] enabled in
            guard let self else { return }
            if enabled {
                // First use of the feature that needs it — never at launch.
                guard PermissionOnboarding.preExplain(.inputMonitoring) else {
                    self.statusItem.eventLoggingEnabled = false
                    return
                }
                if !InputMonitoringAccess.ensureGranted() {
                    // Same shape as Screen Recording: a request returns false
                    // even while the user is granting, so this is "relaunch",
                    // not "denied".
                    PermissionOnboarding.showAlreadyDenied(.inputMonitoring)
                    // Deliberately NOT persisted. Saving `enabled = true` here
                    // left a checkmark on a feature that can never produce an
                    // event — indistinguishable from "the user did not type" —
                    // and left `Recorder` to meet the missing grant mid-
                    // recording, where the TCC dialog it raises lands in frame
                    // with no pre-explain (§4.10), or on the agent path with
                    // nobody there to dismiss it.
                    //
                    // After a first-run grant this means one more toggle on the
                    // next launch, which is the same "relaunch" the alert just
                    // described, and is the honest state in the meantime.
                    self.statusItem.eventLoggingEnabled = false
                    return
                }
            }
            var settings = EventLoggingSettings.load()
            settings.enabled = enabled
            settings.save()
            self.statusItem.eventLoggingEnabled = enabled
        }

        // §12's opt-in crash reporting: no handler, no network — purely
        // whether `snitt diagnostics export` reads Snitt's own `.ips` files
        // and folds redacted summaries into the bundle it already writes.
        statusItem.crashReportingEnabled = CrashReportSettings.load().enabled
        statusItem.onToggleCrashReporting = { [weak self] enabled in
            guard let self else { return }
            var settings = CrashReportSettings.load()
            settings.enabled = enabled
            settings.save()
            self.statusItem.crashReportingEnabled = enabled
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

        let monitor = HotkeyMonitor(combination: .defaultCombination) { [weak self] in
            self?.handleHotkey()
        }
        do {
            try monitor.start()
        } catch {
            notify("Snitt could not register the ⌥⌘5 shortcut — another app may be "
                 + "using it. You can still start and stop recording from the menu bar.")
        }
        hotkey = monitor

        let markerHotkey = HotkeyMonitor(combination: .markerCombination) { [weak self] in
            self?.handleMarkerHotkey()
        }
        do {
            try markerHotkey.start()
        } catch {
            // Reported for the same reason the record hotkey's failure is: a
            // silently dead marker hotkey means a person presses it through a
            // whole demo and finds no markers afterwards.
            notify("Snitt could not register the ⌥⌘M marker shortcut — another app "
                 + "may be using it. Recording is unaffected.")
        }
        self.markerHotkey = markerHotkey

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
                statusItem.update(.recording(startedAt: Date()))
                // A human recording supersedes any agent session the registry
                // still remembers — see AutomationHost.stop().
                await automationHost?.clearAgentSession()
                // The recurring macOS prompt is caused by the cached path only, so
                // explain it at its first actual occurrence — not on the picker path.
                if usedCache { ConsentExplainer.showIfNeeded() }
            case .stopped(let url, let copied):
                statusItem.update(.idle)
                // This press may have been the kill switch ending an AGENT
                // recording. Clearing the registry here is what stops a later
                // `record stop <id>` from believing that session is still live.
                await automationHost?.clearAgentSession()
                if !copied {
                    notify("Recording saved to \(url.lastPathComponent), but it could "
                         + "not be copied to the clipboard.")
                }
            case .cancelled:
                statusItem.update(.idle)
            case .failed(let message, _):
                statusItem.update(.idle)
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

    private func notify(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Task 5 replaces this body with the real Settings window. It exists
    /// here so the menu's selector resolves and ⌘, is not silently dead.
    @objc func showSettings(_ sender: Any?) {
        NSSound.beep()
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

    /// Finder double-click, `open(1)`, and drag-onto-Dock all arrive here.
    /// Can arrive before OR after `applicationDidFinishLaunching` on a cold
    /// launch — this must not depend on anything that method sets up.
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
                    // unreleased feature. Domain/code/description only —
                    // never a path, never `String(describing:)` on the error.
                    let ns = error as NSError
                    Self.log.error("Could not open the document: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .public)")
                    presentOpenFailure(error)
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
