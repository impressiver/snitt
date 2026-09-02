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

        let monitor = HotkeyMonitor(combination: .defaultCombination) { [weak self] in
            self?.handleHotkey()
        }
        try? monitor.start()
        hotkey = monitor

        // §5.3's kill switch: clicking the menu-bar item does the same thing as
        // the hotkey, so a recording can always be stopped by mouse alone —
        // which matters when the hotkey is what someone is demonstrating.
        statusItem.onClick = { [weak self] in
            self?.handleHotkey()
        }
    }

    private func handleHotkey() {
        guard let coordinator else { return }
        Task { @MainActor in
            ConsentExplainer.showIfNeeded()
            let outcome = await coordinator.toggle()
            switch outcome {
            case .started:
                statusItem.update(.recording(startedAt: Date()))
            case .stopped(let url, let copied):
                statusItem.update(.idle)
                notify(copied ? "Copied to clipboard" : "Saved to \(url.lastPathComponent)")
            case .cancelled:
                statusItem.update(.idle)
            case .failed(let message):
                statusItem.update(.idle)
                notify(message)
            case .ignored:
                // A press landed mid-transition. Deliberately silent: the user
                // pressed twice quickly and the first press is still working.
                break
            }
        }
    }

    private func notify(_ message: String) {
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
