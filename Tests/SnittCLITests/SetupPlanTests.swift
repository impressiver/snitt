// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import snitt_cli
@testable import SnittAutomation

/// `snitt setup` — the registration half of D63.
///
/// D63 found the agent surface shipped in no bundle and registered with no
/// host. Embedding the binaries fixed the first half; nothing had yet fixed the
/// second, so the MCP server existed on disk and no agent could reach it.
@Suite
struct SetupPlanTests {
    @Test("The server path is the sibling of the running CLI, not a PATH lookup")
    func mcpPathIsASibling() {
        // Both binaries ship together in Snitt.app/Contents/Helpers, so the
        // copy beside THIS one is the copy that matches this protocol version.
        // Searching PATH, or hardcoding /Applications, can register a stale
        // snitt-mcp from an old build — the exact version mismatch the
        // handshake exists to refuse, arrived at through setup itself.
        // Deliberately NOT under /Applications: a first version of this test
        // used that path, which is exactly what a hardcoded
        // "/Applications/Snitt.app/..." implementation returns — so it passed
        // against the very shortcut it was written to forbid. A build-directory
        // path is also the realistic case during development.
        let path = SetupPlan.siblingMCPPath(
            ofExecutable: "/Users/dev/src/snitt/build/Snitt.app/Contents/Helpers/snitt")
        #expect(path == "/Users/dev/src/snitt/build/Snitt.app/Contents/Helpers/snitt-mcp")
    }

    @Test("Each step uses the host's own registration command")
    func stepsUseFirstPartyCommands() throws {
        // S5 named "owning another tool's config format is a maintenance tail"
        // as the cost of a setup command. Delegating to each host's own CLI is
        // what avoids paying it: the format can change freely as long as the
        // command does not. A step that wrote ~/.claude.json directly would
        // fail this.
        let steps = SetupPlan.steps(mcpPath: "/Apps/Snitt.app/Contents/Helpers/snitt-mcp",
                                    installedExecutables: ["claude"])
        let claude = try #require(steps.first { $0.executable == "claude" })
        #expect(claude.command == ["claude", "mcp", "add", "snitt", "--",
                                   "/Apps/Snitt.app/Contents/Helpers/snitt-mcp"])
        #expect(claude.command.contains("--"),
                "without -- a path that looks like a flag is misread by the host's parser")
    }

    @Test("Installed-ness is reported per host, not assumed")
    func installedIsPerHost() throws {
        let steps = SetupPlan.steps(mcpPath: "/x/snitt-mcp", installedExecutables: ["claude"])
        let claude = try #require(steps.first { $0.executable == "claude" })
        let cursor = try #require(steps.first { $0.executable == "cursor" })
        #expect(claude.isInstalled)
        #expect(!cursor.isInstalled)
    }

    @Test("An absent host still gets its command printed")
    func absentHostsStillGetInstructions() throws {
        // Someone may run `snitt setup` precisely to find out what registering
        // WOULD take. Dropping uninstalled hosts from the plan answers a
        // different question than the one asked.
        let steps = SetupPlan.steps(mcpPath: "/x/snitt-mcp", installedExecutables: [])
        #expect(steps.count == 2)
        #expect(steps.allSatisfy { !$0.command.isEmpty })
    }

    @Test("The server name is fixed, so re-running updates rather than accumulates")
    func serverNameIsStable() throws {
        // A derived name — from the path, or a timestamp — would leave
        // snitt, snitt-1, snitt-2 behind after three runs, and an agent facing
        // three identical tool sets.
        // `#require`, not `[0]`: an implementation that returned an empty plan
        // would TRAP on subscript, and `swift test` reports a crashed bundle
        // with no summary line at all — a mutation that kills the suite by
        // crashing it looks, from the output, like nothing ran.
        let first = try #require(SetupPlan.steps(mcpPath: "/a/snitt-mcp",
                                                 installedExecutables: []).first)
        let second = try #require(SetupPlan.steps(mcpPath: "/b/snitt-mcp",
                                                  installedExecutables: []).first)
        #expect(first.command.contains(SetupPlan.serverName))
        #expect(second.command.contains(SetupPlan.serverName))
        #expect(SetupPlan.serverName == "snitt")
    }

    @Test("setup parses, and --apply is opt-in")
    func setupParsing() {
        guard case .success(.setup(let applyDefault)) = CommandLineParser.parse(["setup"]) else {
            Issue.record("`snitt setup` did not parse"); return
        }
        // Writing to another tool's configuration is a side effect outside this
        // repo. Printing by default means the destructive-ish path is the one
        // you have to ask for.
        #expect(applyDefault == false)

        guard case .success(.setup(true)) = CommandLineParser.parse(["setup", "--apply"]) else {
            Issue.record("--apply did not parse"); return
        }
        guard case .failure = CommandLineParser.parse(["setup", "--wat"]) else {
            Issue.record("an unknown flag was accepted"); return
        }
    }

    @Test("A shell line quotes a path with spaces")
    func shellLineQuotesSpaces() {
        // ~/Applications/My Apps/Snitt.app is ordinary. An unquoted line would
        // be copy-pasted and silently register the wrong thing.
        let step = SetupStep(host: "H", executable: "h", isInstalled: true,
                             command: ["h", "add", "/My Apps/snitt-mcp"])
        #expect(step.shellLine == #"h add "/My Apps/snitt-mcp""#)
    }
}
