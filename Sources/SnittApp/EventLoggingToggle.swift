import Foundation
import SnittCapture

/// §4.10's Input Monitoring consent ladder for the event-logging setting,
/// extracted into one place so the status item and the Settings window
/// apply exactly the same rule rather than each keeping its own copy.
///
/// A duplicated ladder is two ladders that will diverge. The Settings
/// window's first draft did a plain `EventLoggingSettings(enabled:).save()`
/// on toggle — no pre-explain, no grant check — which persisted `enabled =
/// true` with no Input Monitoring grant behind it: exactly the state
/// `AppDelegate`'s original status-item closure was written to prevent (see
/// its "deliberately NOT persisted" comment, which explains why saving
/// `true` there left a checkmark on a feature that can never produce an
/// event). This type is the fix: both surfaces call `apply`, so there is
/// one ladder, not two that can drift apart.
@MainActor
enum EventLoggingToggle {
    /// Attempts to apply `enabled`. Turning OFF always succeeds and
    /// persists. Turning ON runs the ladder: pre-explain, then the actual
    /// TCC request; either failing means the return value is `false` —
    /// never `enabled` — and NOTHING is persisted. The caller must reflect
    /// this return value back into its own UI (menu checkmark or window
    /// checkbox), since the user may have just checked a box that must now
    /// show unchecked.
    ///
    /// The closures exist for testing: `PermissionOnboarding.preExplain`
    /// and `.showAlreadyDenied` show real alerts, and
    /// `InputMonitoringAccess.ensureGranted` touches real, per-machine,
    /// one-shot TCC state — none of which a unit test can drive.
    ///
    /// Found by hand (manual test of the M5c Settings window): this used
    /// to call `showAlreadyDenied()` on EVERY refused grant, including the
    /// very first one. The doc comment even named the reason it shouldn't
    /// — "a request returns false even while the user is granting" — but
    /// never acted on it, unlike `ensureScreenRecordingGrant` in
    /// `main.swift`, which gates the same alert behind
    /// `PermissionOnboarding.followUp(deniedHavingAskedBefore:)`. Without
    /// that gate, checking "Log input events" opens the real System
    /// Settings ▸ Input Monitoring pane (via `CGRequestListenEventAccess`)
    /// AND immediately raises Snitt's own "already denied, open System
    /// Settings" alert on top of it — the alert and the dialog it is
    /// contradicting on screen at once. `hasRequested`/`markRequested` are
    /// what let this distinguish "first ask, awaiting relaunch" (silent)
    /// from "asked before and refused again" (worth telling the user).
    @discardableResult
    static func apply(_ enabled: Bool,
                       defaults: UserDefaults = .standard,
                       preExplain: (UserDefaults) -> Bool = {
                           PermissionOnboarding.preExplain(.inputMonitoring, defaults: $0)
                       },
                       hasRequested: () -> Bool = {
                           PermissionOnboarding.hasRequested(.inputMonitoring)
                       },
                       markRequested: () -> Void = {
                           PermissionOnboarding.markRequested(.inputMonitoring)
                       },
                       ensureGranted: () -> Bool = { InputMonitoringAccess.ensureGranted() },
                       showAlreadyDenied: () -> Void = {
                           PermissionOnboarding.showAlreadyDenied(.inputMonitoring)
                       }) -> Bool {
        if enabled {
            // First use of the feature that needs it — never at launch.
            guard preExplain(defaults) else { return false }

            let askedBefore = hasRequested()
            markRequested()
            if !ensureGranted() {
                switch PermissionOnboarding.followUp(deniedHavingAskedBefore: askedBefore) {
                case .awaitingRelaunch:
                    // Deliberately silent — see `ensureScreenRecordingGrant`.
                    // macOS's own System Settings dialog is on screen and is
                    // the only thing the user should be reading right now;
                    // the grant takes effect on the next launch.
                    break
                case .alreadyDenied:
                    showAlreadyDenied()
                }
                return false
            }
        }
        var settings = EventLoggingSettings.load(defaults)
        settings.enabled = enabled
        settings.save(to: defaults)
        return enabled
    }
}
