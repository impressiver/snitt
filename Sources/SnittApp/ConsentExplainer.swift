import AppKit
import Foundation

/// Explains the recurring macOS re-consent prompt, once (§5.5).
///
/// Every recording — hotkey or not — resolves its target by enumerating
/// windows via `SCShareableContent` (§4.11, D42: the hotkey now presents the
/// picker on every press, rather than reusing a cached target), and macOS
/// charges that enumeration a periodic re-consent prompt, roughly monthly.
/// That cost is accepted deliberately — but an unexplained recurring prompt
/// reads as an app misbehaving, so Snitt explains it the first time rather
/// than letting the user guess.
@MainActor
enum ConsentExplainer {
    private static let shownKey = "com.impressiver.snitt.consentExplainerShown"

    static func showIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: shownKey) else { return }
        defaults.set(true, forKey: shownKey)

        let alert = NSAlert()
        alert.messageText = "macOS will ask about screen recording periodically"
        alert.informativeText = """
        Snitt asks you to pick a window each time you record, and macOS \
        re-confirms screen-recording access periodically — about once a month.

        That prompt is macOS asking, not Snitt. Approving it keeps recording \
        working.
        """
        alert.addButton(withTitle: "Got it")
        alert.runModal()
    }
}
