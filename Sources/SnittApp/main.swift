import AppKit

/// Menu-bar app entry point.
///
/// An accessory app: no Dock icon, no window at launch. §4.11 requires that
/// recording start from a keystroke without a window ever opening, so the app
/// must be able to live entirely in the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.install()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
