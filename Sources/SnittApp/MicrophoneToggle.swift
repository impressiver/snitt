// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittCapture

/// §4.10's Microphone consent ladder for the microphone-capture setting.
///
/// Mirrors `EventLoggingToggle` exactly, both surfaces (status item, Settings
/// window) call `apply`, so there is one ladder for this setting too, not a
/// second copy that can drift from the first. The actual sequence — pre-explain,
/// request, persist-only-on-success — lives in `PermissionLadder`; see its doc
/// comment for why a copy-pasted closure here would be the same defect M5c
/// fixed for event logging, in a new place.
@MainActor
enum MicrophoneToggle {
    /// Attempts to apply `enabled`. Turning OFF always succeeds and persists.
    /// Turning ON runs the ladder: pre-explain, then the actual TCC request;
    /// either failing means the return value is `false` — never `enabled` —
    /// and NOTHING is persisted. The caller must reflect this return value
    /// back into its own UI (menu checkmark or window checkbox), since the
    /// user may have just checked a box that must now show unchecked.
    ///
    /// A grant that fails must never be persisted as `true` — the same rule
    /// `EventLoggingToggle`'s history states: that would leave a checkmark on
    /// a feature that can never produce anything, mic audio in this case.
    ///
    /// The closures exist for testing: `PermissionOnboarding.preExplain` and
    /// `.showAlreadyDenied` show real alerts, and `MicrophoneAccess.ensureGranted`
    /// touches real, per-machine TCC state, neither of which a unit test can
    /// drive.
    @discardableResult
    static func apply(_ enabled: Bool,
                       defaults: UserDefaults = .standard,
                       preExplain: (UserDefaults) -> Bool = {
                           PermissionOnboarding.preExplain(.microphone, defaults: $0)
                       },
                       hasRequested: () -> Bool = {
                           PermissionOnboarding.hasRequested(.microphone)
                       },
                       markRequested: () -> Void = {
                           PermissionOnboarding.markRequested(.microphone)
                       },
                       ensureGranted: () -> Bool = { MicrophoneAccess.ensureGranted() },
                       showAlreadyDenied: () -> Void = {
                           PermissionOnboarding.showAlreadyDenied(.microphone)
                       }) -> Bool {
        PermissionLadder.apply(enabled, defaults: defaults,
                               preExplain: preExplain,
                               hasRequested: hasRequested,
                               markRequested: markRequested,
                               ensureGranted: ensureGranted,
                               showAlreadyDenied: showAlreadyDenied,
                               persist: { newValue in
                                   var settings = MicrophoneSettings.load(defaults)
                                   settings.enabled = newValue
                                   settings.save(to: defaults)
                               })
    }
}
