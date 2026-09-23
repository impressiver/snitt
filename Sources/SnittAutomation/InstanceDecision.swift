// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// What a starting Snitt does about a Snitt already running.
///
/// **There must only ever be one menubar accessory.** macOS does not give that
/// for free: its relaunch-instead-of-launch behaviour keys on the bundle's
/// PATH, not its identifier, so every copy of `Snitt.app` on a machine is a
/// separate instance as far as LaunchServices is concerned. A developer has one
/// in `/Applications` and one per worktree build; a user can have one in
/// `/Applications` and the DMG's copy still mounted. `AppLauncher` launches the
/// bundle containing the CALLING binary, so a CLI in a worktree starts that
/// worktree's app even with the installed one already up — and each new
/// instance used to take the automation socket away from the last, which is why
/// nothing ever complained.
public enum InstanceDecision: Equatable, Sendable {
    /// Nobody else is here. Start normally.
    case proceed
    /// Take over: ask the incumbent to quit, then start.
    case replaceIncumbent
    /// Stand down: the incumbent is doing something that must not be
    /// interrupted. Terminate without showing a window or binding the socket.
    case deferToIncumbent
}

extension InstanceDecision {
    /// - Parameters:
    ///   - otherInstancesRunning: whether any OTHER process of this bundle
    ///     identifier is alive. The caller excludes itself.
    ///   - incumbentIsRecording: what the incumbent said when asked, or `nil`
    ///     when it could not be reached.
    ///
    /// The newcomer wins, but only against an incumbent that has SAID it is
    /// idle. A fresh build is nearly always the copy somebody wants, so
    /// standing down by default would break the rebuild-and-look loop this
    /// guard has to keep working.
    ///
    /// **Silence is not consent.** An earlier version read an unreachable
    /// incumbent as fair game, reasoning that an instance which will not answer
    /// its own socket cannot be stopped or inspected anyway, so taking over was
    /// the only branch that terminated. That reasoning weighed the wrong risk.
    /// The probe asks the recorder actor through the main actor, and during
    /// real capture — with an editor window open and frames arriving — both are
    /// busy; "no answer in three seconds" describes a working app under load
    /// far more often than a wedged one. And the cost of guessing wrong is not
    /// symmetric. Guess "idle" about a recording app and the take is gone:
    /// terminating mid-capture leaves no sidecars and a `capture.mov` with no
    /// moov atom, measured, unopenable. Guess "busy" about a wedged one and a
    /// person quits it from the menu bar, which takes a click.
    ///
    /// So the rule is the conservative one: **never terminate an instance that
    /// has not confirmed it is idle.**
    public static func decide(otherInstancesRunning: Bool,
                              incumbentIsRecording: Bool?) -> InstanceDecision {
        guard otherInstancesRunning else { return .proceed }
        return incumbentIsRecording == false ? .replaceIncumbent : .deferToIncumbent
    }
}
