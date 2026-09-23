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
    /// The newcomer wins by default, because the reason a second copy is being
    /// launched is nearly always that it is the one somebody wants: a fresh
    /// build, a newly installed version. The single exception is a recording in
    /// flight. Quitting then would lose a take with no way back —
    /// `applicationShouldTerminate` flushes pending SAVES, and has nothing to
    /// say about an `AVAssetWriter` mid-file — so a recording outranks whatever
    /// the newcomer was for.
    ///
    /// **An unreachable incumbent is replaced, not deferred to.** That is the
    /// uncomfortable case and it was decided deliberately: an instance that
    /// will not answer its own socket cannot be stopped, inspected or recovered
    /// by any frontend, and deferring to it means every later launch stands
    /// down too. The machine is then stuck with an icon nobody can use, which
    /// is the state this whole guard exists to end. Taking over is the only
    /// choice that terminates.
    public static func decide(otherInstancesRunning: Bool,
                              incumbentIsRecording: Bool?) -> InstanceDecision {
        guard otherInstancesRunning else { return .proceed }
        return incumbentIsRecording == true ? .deferToIncumbent : .replaceIncumbent
    }
}
