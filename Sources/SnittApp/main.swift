import AppKit
import Foundation
import SnittCapture
import SnittDocument

/// Menu-bar app entry point.
///
/// An accessory app: no Dock icon, no window at launch. §4.11 requires that
/// recording start from a keystroke without a window ever opening, so the app
/// must be able to live entirely in the menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()
    private var hotkey: HotkeyMonitor?
    private var markerHotkey: HotkeyMonitor?
    private var coordinator: RecordingCoordinator?
    private var automationHost: AutomationHost?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.install()

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
                guard PermissionOnboarding.preExplain(.inputMonitoring) else { return }
                if !InputMonitoringAccess.ensureGranted() {
                    // Same shape as Screen Recording: a request returns false
                    // even while the user is granting, so this is "relaunch",
                    // not "denied".
                    PermissionOnboarding.showAlreadyDenied(.inputMonitoring)
                }
            }
            var settings = EventLoggingSettings.load()
            settings.enabled = enabled
            settings.save()
            self.statusItem.eventLoggingEnabled = enabled
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
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
