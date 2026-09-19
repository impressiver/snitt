// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import snitt_mcp
import SnittAutomation

/// D106: a refused tool call reaches the agent as something it can branch on.
///
/// Before this, `tools/call` rendered a bridge refusal as
/// `toolError(id: id, problem.message)`: bare prose with `isError: true` and
/// nowhere for a code to travel, while a refusal from the app itself came
/// back code-prefixed. Two error shapes from one server, and the agent-facing
/// contract ("an agent branches on this, never on `message`") reached only one
/// of them.
@Suite
struct ArgumentErrorTests {

    @Test("A refused call carries a code an agent can branch on")
    func refusalCarriesItsCode() throws {
        // WRONG IMPLEMENTATION THIS DISCRIMINATES AGAINST: the pre-D106 call
        // site, `toolError(id: id, problem.message)`, i.e. an
        // `argumentFailure` that returns `(problem.message, nil)`. It still
        // sets `isError`, it still says in English what went wrong, and the
        // model can still often self-correct from the prose, which is exactly
        // why this went unnoticed. Verified to fail by returning the bare
        // message and nil.
        let rendered = argumentFailure(MCPBridgeError("snitt_stop_recording requires sessionId"))
        let structured = try #require(rendered.structured,
                                      "a refusal with no structured half is prose again")
        #expect(structured["code"] as? String == "invalid_arguments")
        #expect(structured["message"] as? String == "snitt_stop_recording requires sessionId")
        #expect(rendered.text.hasPrefix("invalid_arguments: "),
                "the text block carries the code too, the way an app refusal does")
    }

    @Test("A real bad tool call, end to end, arrives with the code on it")
    func aRealCallIsRefusedWithACode() throws {
        // The test above builds its own `MCPBridgeError`, so it would pass
        // even if no code path in the bridge produced one. This drives
        // `MCPBridge.request` with arguments an agent would plausibly send:
        // the wrong TYPE, which is the coercion class this repo has fixed
        // three times. It follows the same route `tools/call` follows.
        //
        // WRONG IMPLEMENTATION: wiring `argumentFailure` up but leaving the
        // `tools/call` switch calling `toolError(id: id, problem.message)`.
        // Verified to fail by reverting that call site.
        guard case .failure(let problem) = MCPBridge.request(
            forTool: "snitt_start_recording",
            arguments: ["bundleIdentifier": "com.apple.Safari", "microphone": "true"]) else {
            Issue.record("a string boolean was accepted"); return
        }
        let structured = try #require(argumentFailure(problem).structured)
        #expect(structured["code"] as? String == "invalid_arguments")
    }

    @Test("A refusal and an app failure have the same shape, not merely the same fields")
    func refusalMatchesAnAppFailure() throws {
        // WRONG IMPLEMENTATION: hand-building the structured half at the call
        // site: `["error": problem.message, "reason": "invalid_arguments"]`
        // or any other plausible spelling. Every assertion above still passes
        // with `code`/`message` renamed, and an agent written against the
        // app's failures would have to special-case the bridge's. §4.8's rule
        // is that the frontends cannot diverge, and this pins the shape to one
        // source. Verified to fail by renaming a key in `argumentFailure`.
        let refusal = try #require(argumentFailure(MCPBridgeError("nope")).structured)
        let appFailure = try #require(structuredContent(
            .failure(AutomationError(code: .invalidArguments, message: "nope"))))
        #expect(Set(refusal.keys) == Set(appFailure.keys),
                "bridge refusal has \(Set(refusal.keys)), app failure has \(Set(appFailure.keys))")
    }

    @Test("A refused call is still flagged as an error, and now says why in both halves")
    func refusalKeepsIsErrorAndGainsStructuredContent() throws {
        // WRONG IMPLEMENTATION: adding `structuredContent` by replacing the
        // hand-built error dictionary with an ordinary `toolResult`, and
        // losing `isError` on the way. A host that branches on `isError`
        // would then read every refusal as a SUCCESS whose text happens to
        // describe a failure, strictly worse than the state D106 set out to
        // fix. Verified to fail by dropping the `isError` line.
        let rendered = argumentFailure(MCPBridgeError("snitt_inspect requires bundlePath"))
        let payload = toolErrorPayload(rendered.text, structured: rendered.structured)
        #expect(payload["isError"] as? Bool == true)
        let structured = try #require(payload["structuredContent"] as? [String: Any])
        #expect(structured["code"] as? String == "invalid_arguments")
        let blocks = try #require(payload["content"] as? [[String: Any]])
        #expect(blocks.first?["text"] as? String == rendered.text,
                "the prose a person reads in a log must survive the addition")
    }
}
