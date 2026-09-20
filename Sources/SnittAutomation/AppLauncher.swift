// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Starts `Snitt.app` when a client finds nothing listening.
///
/// **Must go through LaunchServices, never a direct spawn.** V4: TCC attributes
/// a capability to the *responsible process*, and a child inherits its parent's
/// `p_responsible_pid`. An MCP server that `posix_spawn`s the app binary would
/// therefore make the agent host's terminal responsible for Snitt's screen
/// recording — the exact attribution failure §4.9 exists to prevent, arrived at
/// through the convenience meant to smooth it over. `open(1)` hands the launch
/// to LaunchServices, which makes the app its own responsible process.
public enum AppLauncher {
    /// The `.app` bundle this executable ships inside, if any.
    ///
    /// Walks up from the executable rather than searching `/Applications`, for
    /// the same reason `SetupPlan.siblingMCPPath` does: the bundle around THIS
    /// binary is the one whose protocol version matches it, and launching some
    /// other copy is the version mismatch the handshake exists to refuse.
    public static func containingAppBundle(ofExecutable path: String) -> URL? {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        // Bounded: a path is finite, but a symlink loop is not, and this runs
        // before anything has validated the path.
        for _ in 0..<32 {
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
            if url.pathExtension == "app" { return url }
        }
        return nil
    }

    /// The argv that launches `bundleURL` without stealing focus.
    ///
    /// Pure, so the LaunchServices requirement above is a test rather than a
    /// comment somebody later "simplifies" into an exec.
    ///
    /// `-g` keeps Snitt in the background: §4.13 focuses the RECORDING TARGET
    /// when capture starts, and an app that raised itself first would leave the
    /// agent filming Snitt's own window.
    /// The argument an agent-initiated launch carries, so the app can tell
    /// that nobody asked for a window.
    ///
    /// Without it, a cold start from any agent command wedges the whole
    /// surface: the app launches bare, `offerToOpenADocumentIfLaunchedBare`
    /// runs a modal Open panel, and that panel blocks the MAIN ACTOR — so
    /// `snitt status` still answers (it never hops) while every verb that
    /// needs the main actor times out. It also calls
    /// `NSApp.activate(ignoringOtherApps:)`, so an agent working quietly in
    /// the background yanks a person's focus to a dialog they did not ask for.
    ///
    /// `-g` alone cannot carry this. It asks LaunchServices not to bring the
    /// app forward, which the app cannot read back, and the prompt then
    /// activates over it anyway.
    public static let agentLaunchArgument = "--launched-by-agent"

    public static func launchCommand(for bundleURL: URL) -> [String] {
        ["/usr/bin/open", "-g", "-a", bundleURL.path, "--args", agentLaunchArgument]
    }

    /// Launches and waits until `isReady` says the app is reachable. Returns
    /// false if it never is — the caller reports the original "not running",
    /// which is still true and still actionable.
    ///
    /// Readiness is a CONNECT, not the socket file existing. The file outlives
    /// the process that made it: quitting Snitt leaves it behind, so a check
    /// for its presence says "running" for every launch after the first. That
    /// is the common case, and the first version of this guarded on the file
    /// and therefore never fired.
    public static func launchAndWait(bundleURL: URL,
                                     timeout: TimeInterval = 10,
                                     isReady: () -> Bool) -> Bool {
        let command = launchCommand(for: bundleURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }

        // `open` returns as soon as LaunchServices accepts the request, which is
        // well before the app has bound its socket.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isReady() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}
