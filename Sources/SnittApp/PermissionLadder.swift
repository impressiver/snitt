import Foundation

/// The mechanics of §4.10's permission ladder, factored out of
/// `EventLoggingToggle` so `MicrophoneToggle` runs the exact same rule
/// instead of keeping a second copy.
///
/// `EventLoggingToggle` is the type this was extracted FROM, not a sibling
/// written independently — see ITS doc comment for the full history of why a
/// duplicated ladder is a defect: the Settings window's first draft did a
/// plain `EventLoggingSettings(enabled:).save()` on toggle, with no
/// pre-explain and no grant check, which persisted `enabled = true` with no
/// Input Monitoring grant behind it. Adding the microphone toggle by copying
/// that closure into a second type would have been the same mistake in a new
/// place — two ladders that can drift apart the next time either one is
/// fixed. This is the one place the sequence itself lives; `EventLoggingToggle`
/// and `MicrophoneToggle` each supply only the parts that differ (which
/// service, which settings type).
@MainActor
enum PermissionLadder {
    /// Turning OFF always succeeds and persists (via `persist`). Turning ON
    /// runs the ladder: pre-explain, then the actual TCC request; either
    /// failing means the return value is `false` — never `enabled` — and
    /// `persist` is NEVER called. The caller must reflect this return value
    /// back into its own UI (menu checkmark or window checkbox), since the
    /// user may have just checked a box that must now show unchecked.
    ///
    /// This is the rule stated on `EventLoggingToggle`'s own history: a
    /// grant that failed must never be persisted as `true`, because that
    /// leaves a checkmark on a feature that can never produce anything —
    /// logged events for that toggle, mic audio for this one.
    @discardableResult
    static func apply(_ enabled: Bool,
                       defaults: UserDefaults,
                       preExplain: (UserDefaults) -> Bool,
                       hasRequested: () -> Bool,
                       markRequested: () -> Void,
                       ensureGranted: () -> Bool,
                       showAlreadyDenied: () -> Void,
                       persist: (Bool) -> Void) -> Bool {
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
                    // the only thing the user should be reading right now.
                    break
                case .alreadyDenied:
                    showAlreadyDenied()
                }
                return false
            }
        }
        persist(enabled)
        return enabled
    }
}
