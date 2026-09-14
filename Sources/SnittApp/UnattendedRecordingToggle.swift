// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittAutomation
import SnittCapture

/// D95's unattended opt-in, run through §4.10's permission ladder.
///
/// **Confirming the permission is the whole mechanism, not a side effect.**
/// Screen Recording is otherwise requested lazily, at first record — which is
/// exactly the wrong moment for this feature, because the point of it is that
/// nobody is there. Turning the setting on is the one instant a person is
/// guaranteed to be at the machine, so that is when the grant is confirmed:
/// this is the "trigger the required macOS permissions when enabled" half of
/// the request, and the reason a plain
/// `AgentSettings(unattendedRecordingEnabled: true).save()` would be a lie.
///
/// The ladder's existing rule carries the rest: a refused grant persists
/// NOTHING and returns `false`, so the checkbox reverts rather than sitting
/// checked over a permission the app does not have. `EventLoggingToggle`'s doc
/// comment records why that rule exists and what it cost to learn.
///
/// The third sibling of `EventLoggingToggle` and `MicrophoneToggle`; all three
/// supply only what differs (which service, which settings type) and share
/// `PermissionLadder` for the sequence itself.
@MainActor
enum UnattendedRecordingToggle {
    /// Attempts to apply `enabled`, returning the state actually persisted.
    ///
    /// - Parameter now: the clock, injected. Enabling STAMPS this, and the
    ///   stamp is what expires thirty days later — a toggle that persisted the
    ///   flag without it would leave `unattendedGrant` reading `.off` forever,
    ///   which is the failure mode this parameter exists to make testable.
    ///
    /// `hasRequested` and `markRequested` take the store rather than closing
    /// over `.standard` the way the two sibling toggles' defaults do. Same
    /// behaviour in production, where the store IS `.standard`; the difference
    /// is that a test can exercise the production closures against a fixture
    /// suite instead of having to override them to avoid writing to the user's
    /// real preference domain — which is what lets the service these ask about
    /// be asserted rather than assumed.
    @discardableResult
    static func apply(_ enabled: Bool,
                       defaults: UserDefaults = .standard,
                       now: () -> Date = { Date() },
                       preExplain: (UserDefaults) -> Bool = {
                           PermissionOnboarding.preExplain(.screenRecording, defaults: $0)
                       },
                       hasRequested: (UserDefaults) -> Bool = {
                           PermissionOnboarding.hasRequested(.screenRecording, defaults: $0)
                       },
                       markRequested: (UserDefaults) -> Void = {
                           PermissionOnboarding.markRequested(.screenRecording, defaults: $0)
                       },
                       ensureGranted: () -> Bool = { ScreenRecordingAccess.ensureGranted() },
                       showAlreadyDenied: () -> Void = {
                           PermissionOnboarding.showAlreadyDenied(.screenRecording)
                       }) -> Bool {
        PermissionLadder.apply(enabled, defaults: defaults,
                               preExplain: preExplain,
                               hasRequested: { hasRequested(defaults) },
                               markRequested: { markRequested(defaults) },
                               ensureGranted: ensureGranted,
                               showAlreadyDenied: showAlreadyDenied,
                               persist: { newValue in
                                   var settings = AgentSettings.load(defaults)
                                   settings.unattendedRecordingEnabled = newValue
                                   // Turning it off CLEARS the confirmation, so
                                   // the next enable buys a fresh thirty days
                                   // rather than inheriting the tail of the
                                   // last one. Renewing is turning it off and
                                   // on again, and that has to mean something.
                                   settings.unattendedConfirmedAt = newValue ? now() : nil
                                   settings.save(to: defaults)
                               })
    }
}
