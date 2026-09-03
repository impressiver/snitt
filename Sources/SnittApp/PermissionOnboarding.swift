import AppKit
import Foundation

/// The pre-explain step of §4.10's permission ladder.
///
/// macOS TCC dialogs cannot be merged, so the only thing Snitt controls is
/// whether one is EXPECTED. A prompt the user was told about reads as normal
/// software; one that appears unannounced reads as an app grabbing at their
/// machine. The sheet is shown once per service, never again.
public enum PermissionOnboarding {
    public enum Service: String, CaseIterable, Sendable {
        case screenRecording
        case microphone

        var displayName: String {
            switch self {
            case .screenRecording: return "Screen Recording"
            case .microphone: return "Microphone"
            }
        }

        var why: String {
            switch self {
            case .screenRecording:
                return "Snitt records the window you choose, plus its audio. "
                     + "macOS covers both under one permission."
            case .microphone:
                return "You turned on voiceover, so Snitt needs the microphone. "
                     + "Recordings without voiceover never use it."
            }
        }
    }

    private static func key(_ service: Service) -> String {
        "com.impressiver.snitt.preExplained.\(service.rawValue)"
    }

    public static func shouldPreExplain(_ service: Service,
                                        defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: key(service))
    }

    public static func markPreExplained(_ service: Service,
                                        defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key(service))
    }

    /// Deep link to the exact Settings pane for a service.
    ///
    /// Needed because macOS shows a TCC prompt only ONCE. After a denial,
    /// requesting again returns false with no dialog, so an app that keeps
    /// "requesting" looks broken. Sending the user to the right list is the
    /// only remaining action.
    public static func settingsURL(for service: Service) -> URL {
        switch service {
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security"
                             + "?Privacy_ScreenCapture")!
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security"
                             + "?Privacy_Microphone")!
        }
    }

    /// Shows the pre-explain sheet, returning whether the user chose to continue.
    @MainActor
    public static func preExplain(_ service: Service,
                                  defaults: UserDefaults = .standard) -> Bool {
        guard shouldPreExplain(service, defaults: defaults) else { return true }
        markPreExplained(service, defaults: defaults)

        let alert = NSAlert()
        alert.messageText = "Snitt needs \(service.displayName)"
        alert.informativeText = service.why + "\n\nmacOS will ask next."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Explains that the grant was already denied and offers the Settings pane.
    ///
    /// The "relaunch, not immediately" wording is not a guess: spike S5
    /// observed `CGRequestScreenCaptureAccess()` returning `false` WHILE the
    /// user was granting permission in the dialog it had just raised — the
    /// grant only takes effect on the next launch. Reporting that as a
    /// denial would tell the user their correct action failed.
    @MainActor
    public static func showAlreadyDenied(_ service: Service) {
        let alert = NSAlert()
        alert.messageText = "\(service.displayName) is turned off for Snitt"
        alert.informativeText =
            "macOS only asks once. Turn Snitt on in System Settings, then relaunch it — "
          + "the grant takes effect on the next launch, not immediately."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(settingsURL(for: service))
        }
    }
}
