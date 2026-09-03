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
        Task { @MainActor in
            let outcome = await coordinator.toggle()
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
