// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

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
///
/// The ladder's actual mechanics now live in `PermissionLadder`, extracted
/// when the microphone toggle needed the exact same rule — see that type's
/// doc comment. This type supplies only what differs: which
/// `PermissionOnboarding.Service` and `InputMonitoringAccess`, and where the
/// result persists (`EventLoggingSettings`).
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
        PermissionLadder.apply(enabled, defaults: defaults,
                               preExplain: preExplain,
                               hasRequested: hasRequested,
                               markRequested: markRequested,
                               ensureGranted: ensureGranted,
                               showAlreadyDenied: showAlreadyDenied,
                               persist: { newValue in
                                   var settings = EventLoggingSettings.load(defaults)
                                   settings.enabled = newValue
                                   settings.save(to: defaults)
                               })
    }
}
