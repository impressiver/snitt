// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import Testing
@testable import SnittAutomation
@testable import SnittDocument

/// Reporting a keystroke as a content-free beat (D72, amended).
///
/// Reported keystrokes were refused outright, on the reasoning that letting a
/// caller write typed input into a recording is "a claim about a person rather
/// than about itself". That reasoning is about CONTENT. A beat carrying no
/// text makes only the claim `cursor` was already trusted to make — "something
/// I did happened at this instant" — at the same level of trust and with the
/// same `reported` provenance.
///
/// It exists because an agent driving a terminal otherwise cannot mark its work
/// at all: `autoTrimRange` finds bookends from input events, and typing
/// produced none.
@Suite
struct ReportedKeystrokeTests {

    @Test("The CLI reports a keystroke with no position and no text")
    func cliTakesNoCoordinates() {
        guard case .success(.recordInput(let session, let kind, let x, let y)) =
                CommandLineParser.parse(["record", "keystroke", "S1"]) else {
            Issue.record("`record keystroke S1` did not parse"); return
        }
        #expect(session == "S1")
        #expect(kind == "keystroke")
        #expect(x == nil && y == nil, "a keystroke was given a position")
    }

    @Test("Pointer kinds still require a position")
    func pointerKindsStillNeedCoordinates() {
        // Relaxing this for keystrokes must not relax it for clicks: a click
        // with no position is one Snitt can neither draw nor reason about.
        guard case .failure = CommandLineParser.parse(["record", "click", "S1"]) else {
            Issue.record("a click was accepted with no coordinates"); return
        }
        guard case .success(.recordInput(_, _, let x, let y)) =
                CommandLineParser.parse(["record", "click", "S1", "0.5", "0.25"]) else {
            Issue.record("a well-formed click did not parse"); return
        }
        #expect(x == 0.5 && y == 0.25)
    }

    @Test("The MCP tool accepts a keystroke with no x or y")
    func mcpAcceptsAKeystrokeWithoutAPosition() {
        guard case .success(.reportInput(_, let kind, let x, let y, _)) = MCPBridge.request(
            forTool: "snitt_report_input",
            arguments: jsonArguments(#"{"sessionId": "S1", "kind": "keystroke"}"#)) else {
            Issue.record("a keystroke with no position was refused"); return
        }
        #expect(kind == "keystroke")
        // Nil, not zero. Zero is a real corner of the window, and writing it
        // would put every reported keystroke at the top-left.
        #expect(x == nil && y == nil)
    }

    @Test("A keystroke carrying text is refused")
    func labelledKeystrokeIsRefused() {
        // The restriction that makes this acceptable at all. Without it, a
        // caller could write "the user typed <password>" into a recording.
        guard case .failure(let error) = MCPBridge.request(
            forTool: "snitt_report_input",
            arguments: jsonArguments(
                #"{"sessionId": "S1", "kind": "keystroke", "label": "sudo rm -rf /"}"#)) else {
            Issue.record("accepted a keystroke with a label"); return
        }
        #expect(error.message.lowercased().contains("label")
                || error.message.lowercased().contains("what"),
                "the refusal does not say why: \(error.message)")
    }

    @Test("A pointer kind through MCP still requires x and y")
    func mcpPointerStillRequiresPosition() {
        guard case .failure = MCPBridge.request(
            forTool: "snitt_report_input",
            arguments: jsonArguments(#"{"sessionId": "S1", "kind": "click"}"#)) else {
            Issue.record("a click with no position was accepted"); return
        }
    }

    @Test("The advertised kinds include keystroke and say it carries no text")
    func schemaAdvertisesTheBeat() throws {
        let tool = try #require(MCPBridge.toolDefinitions()
            .first { $0.name == "snitt_report_input" })
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        let kind = try #require(properties["kind"] as? [String: Any])
        let values = try #require(kind["enum"] as? [String])
        #expect(Set(values) == ["click", "cursor", "keystroke"])
        let text = try #require(kind["description"] as? String)
        // An agent that does not know the label is forbidden will send one and
        // be refused mid-recording.
        #expect(text.lowercased().contains("never what") || text.lowercased().contains("not what"),
                "does not warn that content is forbidden: \(text)")
    }

    @Test("Reported keystrokes give auto-trim the bookends it needs")
    func keystrokesUnlockAutoTrim() throws {
        // The whole point. A terminal-driven session reports typing and
        // nothing else; auto-trim previously refused it for want of input.
        let typed = [
            LoggedEvent(timeSeconds: 6.0, kind: .keystroke, source: .reported),
            LoggedEvent(timeSeconds: 14.0, kind: .keystroke, source: .reported),
        ]
        let range = try EditDecisionList.autoTrimRange(events: typed, duration: 20)
        #expect(abs(range.start - 5.5) < 0.001)
        #expect(abs(range.end - 14.5) < 0.001)
    }
}
