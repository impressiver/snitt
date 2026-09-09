// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// One host's registration step.
public struct SetupStep: Codable, Equatable, Sendable {
    /// Human name, e.g. "Claude Code".
    public let host: String
    /// The executable that performs the registration, e.g. `claude`.
    public let executable: String
    /// Whether that executable was found on this machine.
    public let isInstalled: Bool
    /// The exact argv to run. Printed whether or not the host is installed —
    /// an absent host is worth showing, because the reason someone runs
    /// `snitt setup` may be to find out what registering WOULD take.
    public let command: [String]

    public init(host: String, executable: String, isInstalled: Bool, command: [String]) {
        self.host = host
        self.executable = executable
        self.isInstalled = isInstalled
        self.command = command
    }

    /// The command as a copy-pasteable line.
    public var shellLine: String {
        command.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }
}

/// The JSON `snitt setup` writes to stdout — §4.8's agent-facing contract.
public struct SetupReport: Codable, Equatable, Sendable {
    public let mcpPath: String
    public let applied: Bool
    public let steps: [SetupStep]

    public init(mcpPath: String, applied: Bool, steps: [SetupStep]) {
        self.mcpPath = mcpPath
        self.applied = applied
        self.steps = steps
    }
}

/// What `snitt setup` would do, computed without touching the filesystem.
///
/// D63 found the agent surface shipped in no bundle and registered with no host.
/// The bundle half is fixed; this is the registration half.
///
/// **Every step uses the host's OWN first-party command** — `claude mcp add`,
/// `cursor --add-mcp` — rather than writing that host's config file directly.
/// S5's table named "owning another tool's config format is a maintenance tail;
/// every host that changes it breaks this" as the cost of a `snitt setup`, and
/// delegating to the host's own CLI is what avoids paying it: the format can
/// change freely as long as the command does not.
public enum SetupPlan {
    /// The server name registered with each host. Fixed, not derived, because
    /// it is what an agent sees and re-running setup must update the same entry
    /// rather than accumulate `snitt-1`, `snitt-2`.
    public static let serverName = "snitt"

    public static func steps(mcpPath: String,
                             installedExecutables: Set<String>) -> [SetupStep] {
        [
            SetupStep(
                host: "Claude Code",
                executable: "claude",
                isInstalled: installedExecutables.contains("claude"),
                // `--` separates the server command from claude's own flags, so
                // a path containing something flag-shaped cannot be misread.
                command: ["claude", "mcp", "add", serverName, "--", mcpPath]),
            SetupStep(
                host: "Cursor",
                executable: "cursor",
                isInstalled: installedExecutables.contains("cursor"),
                command: ["cursor", "--add-mcp",
                          #"{"name":"\#(serverName)","command":"\#(mcpPath)"}"#]),
        ]
    }

    /// The MCP server that ships beside the running CLI.
    ///
    /// Resolved as a SIBLING of the executable rather than searched for on
    /// PATH or hardcoded to `/Applications`. Both binaries ship together inside
    /// `Snitt.app/Contents/Helpers` (D63), so the copy beside *this* one is the
    /// copy that matches this protocol version — and registering a stale
    /// `snitt-mcp` from an old build is exactly the version mismatch the
    /// handshake exists to refuse.
    public static func siblingMCPPath(ofExecutable executablePath: String) -> String {
        URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .appending(path: "snitt-mcp")
            .path
    }
}
