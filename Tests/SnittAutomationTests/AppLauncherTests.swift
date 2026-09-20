// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittAutomation

/// Starting Snitt.app when nothing is listening.
///
/// The load-bearing test is `launchGoesThroughLaunchServices`. V4: TCC
/// attributes to the RESPONSIBLE process and a child inherits its parent's
/// `p_responsible_pid`, so spawning the app binary directly would make the
/// agent host's terminal responsible for Snitt's screen recording — the exact
/// attribution failure §4.9 exists to prevent, reached through the convenience
/// meant to smooth it over.
@Suite
struct AppLauncherTests {
    @Test("The launch goes through LaunchServices, never a direct exec")
    func launchGoesThroughLaunchServices() {
        let command = AppLauncher.launchCommand(
            for: URL(fileURLWithPath: "/Applications/Snitt.app"))
        #expect(command.first == "/usr/bin/open",
                "launching the executable directly makes the caller TCC-responsible")
        #expect(command.contains("-a"))
        // The bundle path, and it must come before `--args`: everything after
        // that belongs to the app, so a bundle path on the wrong side of it is
        // passed to Snitt as an argument instead of being launched.
        guard let bundleIndex = command.firstIndex(of: "/Applications/Snitt.app") else {
            Issue.record("the bundle is not in \(command)"); return
        }
        if let argsIndex = command.firstIndex(of: "--args") {
            #expect(bundleIndex < argsIndex, "the bundle must precede --args: \(command)")
        }
    }

    @Test("The launch does not steal focus")
    func launchStaysInBackground() {
        // §4.13 focuses the RECORDING TARGET when capture starts. An app that
        // raised itself first would leave an agent filming Snitt's own window.
        let command = AppLauncher.launchCommand(for: URL(fileURLWithPath: "/x/Snitt.app"))
        #expect(command.contains("-g"), "without -g Snitt takes focus from the target")
    }

    @Test("The bundle is found by walking up from the executable")
    func findsTheContainingBundle() {
        // The bundle around THIS binary is the one whose protocol version
        // matches it; searching /Applications could launch an older copy and
        // produce the version mismatch the handshake exists to refuse.
        let found = AppLauncher.containingAppBundle(
            ofExecutable: "/Users/x/build/Snitt.app/Contents/Helpers/snitt-mcp")
        #expect(found?.path == "/Users/x/build/Snitt.app")
    }

    @Test("An executable outside any bundle has none")
    func looseBinaryHasNoBundle() {
        // `.build/debug/snitt-mcp` during development: there is no app to
        // launch, and the caller must report "not running" rather than invent
        // one.
        #expect(AppLauncher.containingAppBundle(
            ofExecutable: "/Users/x/src/.build/debug/snitt-mcp") == nil)
    }

    @Test("The innermost enclosing bundle wins")
    func innermostBundleWins() {
        // A helper nested inside a bundle inside another bundle — Sparkle's
        // Updater.app lives exactly like this — must resolve to its own.
        let found = AppLauncher.containingAppBundle(
            ofExecutable: "/A/Outer.app/Contents/MacOS/Inner.app/Contents/MacOS/tool")
        #expect(found?.path == "/A/Outer.app/Contents/MacOS/Inner.app")
    }

    @Test("A root-level path terminates rather than looping")
    func rootTerminates() {
        #expect(AppLauncher.containingAppBundle(ofExecutable: "/tool") == nil)
    }
}

/// Reachability is a CONNECT, not a file check.
///
/// This is the defect the first implementation shipped with. It guarded on the
/// socket FILE existing, which sounds equivalent and is not: the file outlives
/// the process that created it, so after Snitt has been run and quit once, the
/// check reports "running" forever and the launch never fires. Every unit test
/// passed; the feature did nothing on a real machine.
@Suite
struct SocketReachabilityTests {
    private func makeSocketPath() -> String {
        FileManager.default.temporaryDirectory
            .appending(path: "snitt-probe-\(UUID().uuidString).sock").path
    }

    /// Binds and listens, returning the fd so the caller can close it.
    private func listen(at path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLength) { dst in
                path.withCString { src in strcpy(dst, src) }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        _ = Darwin.listen(fd, 1)
        return fd
    }

    @Test("A live listener is reachable")
    func liveListenerIsReachable() {
        let path = makeSocketPath()
        let fd = listen(at: path)
        defer { close(fd); try? FileManager.default.removeItem(atPath: path) }
        #expect(AutomationClient.canConnect(to: path))
    }

    @Test("A socket file left behind by a dead process is NOT reachable")
    func staleSocketFileIsNotReachable() {
        // The exact state a quit leaves: the file is still on disk, nothing is
        // listening. A `fileExists` check calls this "running".
        let path = makeSocketPath()
        let fd = listen(at: path)
        close(fd)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(FileManager.default.fileExists(atPath: path),
                "the file should still be there — that is the whole problem")
        #expect(!AutomationClient.canConnect(to: path),
                "a dead socket reported as reachable — the launch will never fire")
    }

    @Test("A path with nothing at all is not reachable")
    func missingSocketIsNotReachable() {
        #expect(!AutomationClient.canConnect(to: makeSocketPath()))
    }
}
