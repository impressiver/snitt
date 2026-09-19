// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import snitt_mcp
import SnittDocument
import SnittAutomation

/// D103: an MCP tool result carries a machine-readable object, not only prose.
///
/// §4.8 wrote an agent-facing output contract ("structured JSON on stdout")
/// and §15 scoped it to the CLI, so the MCP server never had one. The result
/// was that `describe` rendered `.targets` and `.status` as encoded JSON and
/// everything else as sentences, and an agent had to pattern-match a sentence
/// to recover a `sessionId` or `bundlePath` — values thirteen tool signatures
/// require as INPUT.
@Suite
struct StructuredContentTests {

    /// Every test here discriminates against the same wrong implementation:
    /// returning `nil` (or omitting the key), which leaves the prose as the
    /// only machine-readable surface and is exactly the state before D103.

    @Test("A started recording returns its session id as a field, not only inside a sentence")
    func startedCarriesSessionId() throws {
        let structured = try #require(
            structuredContent(.started(sessionID: "abc123", target: "Safari")))
        #expect(structured["sessionId"] as? String == "abc123")
        #expect(structured["target"] as? String == "Safari")
    }

    @Test("A stopped recording returns its bundle path as a field")
    func stoppedCarriesBundlePath() throws {
        let structured = try #require(
            structuredContent(.stopped(bundlePath: "/tmp/demo.snitt", health: nil)))
        #expect(structured["bundlePath"] as? String == "/tmp/demo.snitt")
        // Absent health omits the key rather than shipping an empty object,
        // matching the CLI's `emitObject` and the "absent means absent" rule.
        #expect(structured["health"] == nil)
    }

    @Test("Inspect carries capture health and git context, which the prose drops")
    func inspectCarriesHealthAndGit() throws {
        // The sharpest case. `InspectReport` exists, in its own words, "so an
        // agent can write something factually true in a pull request instead of
        // narrating a recording it has never seen" — and `describe` renders
        // only duration, marker count and labels, dropping the two fields that
        // claim actually rests on. The CLI emitted the whole report all along.
        // Decoded from JSON rather than built with an initialiser: that is the
        // shape the app actually sends, and it keeps the test honest about the
        // wire format rather than about a Swift memberwise init.
        let json = #"""
        {"bundlePath": "/tmp/demo.snitt", "createdAt": 0, "initiator": "agent",
         "durationSeconds": 12, "markers": [], "markerCount": 0,
         "inputEventCount": 0, "reportedEventCount": 0,
         "health": {"micRMS": 0.2, "meanFrameVariance": 0.5},
         "git": {"branch": "main", "commit": "abc1234"}}
        """#
        let report = try JSONDecoder().decode(InspectReport.self, from: Data(json.utf8))

        let structured = try #require(structuredContent(.inspected(report)))
        let health = try #require(structured["health"] as? [String: Any])
        #expect(health["micRMS"] as? Double == 0.2)
        let git = try #require(structured["git"] as? [String: Any])
        #expect(git["branch"] as? String == "main")

        // And the prose genuinely does not carry them, so this is a real gap
        // rather than a duplicated one.
        let prose = describe(.inspected(report))
        #expect(!prose.contains("abc1234"))
    }

    @Test("A failure carries its code as a field, since agents branch on the code")
    func failureCarriesCode() throws {
        // `Protocol.swift` says "An agent branches on this [code], never on
        // `message`", which it cannot do while the code is only a prefix on a
        // string.
        let errorJSON = #"{"code": "already_recording", "message": "A recording is already in progress."}"#
        let decoded = try JSONDecoder().decode(AutomationError.self, from: Data(errorJSON.utf8))
        let structured = try #require(structuredContent(.failure(decoded)))
        #expect(structured["code"] as? String == "already_recording")
    }

    @Test("Targets and estimates are named, because structuredContent must be an object")
    func arraysAreNamedNotBare() throws {
        let structured = try #require(structuredContent(.targets([])))
        #expect(structured["targets"] as? [Any] != nil)
    }

    @Test("A tool result keeps the prose text block alongside the structured object")
    func toolResultCarriesBothHalves() throws {
        // Discriminates against replacing the text with structured output:
        // the prose is what a person reads in a host's log, and hosts that do
        // not understand `structuredContent` must keep working unchanged.
        let payload = toolResult("Recording Safari. Session id: abc123",
                                 structured: ["sessionId": "abc123"])
        let content = try #require(payload["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "Recording Safari. Session id: abc123")
        let structured = try #require(payload["structuredContent"] as? [String: Any])
        #expect(structured["sessionId"] as? String == "abc123")
    }

    @Test("A response with no structured form omits the key rather than sending an empty object")
    func nilStructuredOmitsTheKey() {
        let payload = toolResult("something happened", structured: nil)
        #expect(payload["structuredContent"] == nil)
        #expect(payload["content"] != nil)
    }

    // MARK: - D104

    @Test("A start that truncated the vocabulary says so, as a field and in the prose")
    func startedReportsTruncation() throws {
        // Discriminates against the pre-D104 frontends, which built
        // `["sessionId": id, "target": target]` and the sentence "Recording X.
        // Session id: Y" from two associated values and had nowhere to put a
        // third. Against that implementation the key is absent and the sentence
        // carries no number, and both expectations below fail.
        let response = AutomationResponse.started(sessionID: "abc123", target: "Safari",
                                                  vocabularyDropped: 50)
        let structured = try #require(structuredContent(response))
        #expect(structured["vocabularyDropped"] as? Int == 50)
        // And the prose carries it too, because a host that ignores
        // `structuredContent` is exactly the case that made this silent.
        #expect(describe(response).contains("50"))
    }

    @Test("A start with no vocabulary omits the key rather than reporting zero dropped")
    func startedOmitsTheKeyWhenNothingWasSent() throws {
        // Discriminates against `payload["vocabularyDropped"] = dropped ?? 0`,
        // which answers "you sent terms and all were kept" to a caller that
        // sent none: a confidently wrong answer to a question never asked.
        let structured = try #require(
            structuredContent(.started(sessionID: "abc123", target: "Safari")))
        #expect(structured["vocabularyDropped"] == nil)
        #expect(structured["sessionId"] as? String == "abc123")
    }

    @Test("Status carries the consent block, so an agent can check before it calls")
    func statusCarriesConsent() throws {
        // Discriminates against the pre-D104 `StatusInfo`, which carried only
        // recording/sessionID/elapsed/paused. Against that, `consent` is
        // absent and every expectation below fails. Decoded from JSON rather
        // than built with the initialiser: that is the shape the app actually
        // sends, so this stays honest about the wire format.
        let json = #"""
        {"recording": false, "paused": false,
         "consent": {"agentRecording": true, "fullDisplay": false,
                     "unattended": "lapsed", "unattendedPermitted": false}}
        """#
        let info = try JSONDecoder().decode(StatusInfo.self, from: Data(json.utf8))
        let structured = try #require(structuredContent(.status(info)))
        let consent = try #require(structured["consent"] as? [String: Any])
        #expect(consent["agentRecording"] as? Bool == true)
        #expect(consent["fullDisplay"] as? Bool == false)
        #expect(consent["unattended"] as? String == "lapsed")
        #expect(consent["unattendedPermitted"] as? Bool == false)
    }
}
