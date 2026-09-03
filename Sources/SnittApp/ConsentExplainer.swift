import AppKit
import Foundation

/// Explains the recurring macOS re-consent prompt, once (§5.5).
///
/// Hotkey recordings resolve targets via `SCShareableContent`, which macOS
/// charges a monthly re-consent prompt for. That cost is accepted deliberately
/// (§4.11) — but an unexplained recurring prompt reads as an app misbehaving,
/// so Snitt explains it the first time rather than letting the user guess.
@MainActor
enum ConsentExplainer {
    private static let shownKey = "com.impressiver.snitt.consentExplainerShown"

    static func showIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: shownKey) else { return }
        defaults.set(true, forKey: shownKey)

        let alert = NSAlert()
        alert.messageText = "macOS will ask about screen recording periodically"
        alert.informativeText = """
        To start recording instantly from a keystroke, Snitt reuses your last \
        chosen window rather than asking you to pick one every time.

        macOS re-confirms screen-recording access for apps that work this way, \
        about once a month. That prompt is macOS asking, not Snitt — approving \
        it keeps instant capture working.
        """
        alert.addButton(withTitle: "Got it")
        alert.runModal()
    }
}
