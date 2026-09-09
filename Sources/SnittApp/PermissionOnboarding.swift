// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

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
        case inputMonitoring

        var displayName: String {
            switch self {
            case .screenRecording: return "Screen Recording"
            case .microphone: return "Microphone"
            case .inputMonitoring: return "Input Monitoring"
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
            case .inputMonitoring:
                // Says "anywhere on this Mac" deliberately. The tap is a
                // session-wide CGEventTap while the video is window-scoped, so
                // the log also covers typing in windows kept out of frame —
                // and the earlier copy, by naming only recordings, implied the
                // recorded window. "Never which keys" stays: it is still true
                // and it is the half that matters most.
                return "You turned on input logging, so Snitt can record WHEN "
                     + "you click and type — never which keys. This covers "
                     + "activity anywhere on this Mac while recording, not "
                     + "just the window being recorded. Times are rounded so "
                     + "dead air can be trimmed later."
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

    private static func requestedKey(_ service: Service) -> String {
        "com.impressiver.snitt.requested.\(service.rawValue)"
    }

    /// Whether Snitt has ever RAISED the system prompt for this service.
    ///
    /// Distinct from `shouldPreExplain`: that records whether we explained,
    /// this records whether macOS was actually asked.
    public static func hasRequested(_ service: Service,
                                    defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: requestedKey(service))
    }

    public static func markRequested(_ service: Service,
                                     defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: requestedKey(service))
    }

    /// What a `false` from a TCC request actually means.
    public enum RequestFollowUp: Equatable, Sendable {
        /// The dialog is on screen right now (or was, this launch) and the
        /// grant lands on the NEXT launch. Nothing may be shown: spike S5
        /// observed `CGRequestScreenCaptureAccess()` returning false WHILE the
        /// user was granting, so the "turned off, macOS only asks once" sheet
        /// would appear on top of the dialog that is asking.
        case awaitingRelaunch
        /// Snitt has asked before and been refused. macOS raises no second
        /// dialog, so the only remaining action is the Settings deep link.
        case alreadyDenied
    }

    /// Decides which follow-up a denied request earns.
    ///
    /// Pure, because the first-run sequence it governs — pre-explain, system
    /// dialog, immediate `false` — cannot be reproduced in a test: TCC state is
    /// per-machine and one-shot.
    public static func followUp(deniedHavingAskedBefore askedBefore: Bool) -> RequestFollowUp {
        askedBefore ? .alreadyDenied : .awaitingRelaunch
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
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security"
                             + "?Privacy_ListenEvent")!
        }
    }

    /// Shows the pre-explain sheet, returning whether the user chose to continue.
    @MainActor
    public static func preExplain(_ service: Service,
                                  defaults: UserDefaults = .standard) -> Bool {
        guard shouldPreExplain(service, defaults: defaults) else { return true }
        markPreExplained(service, defaults: defaults)

        // A background app's modal can open behind whatever the user is
        // looking at, with nothing obvious to bring it forward.
        // `AppDelegate.notify()` activates for exactly this reason.
        NSApp.activate(ignoringOtherApps: true)
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
        NSApp.activate(ignoringOtherApps: true)
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
