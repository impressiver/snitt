// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittAutomation

/// D106: the error taxonomy an agent can actually branch on.
///
/// `AutomationError.Code` says "an agent branches on this, never on
/// `message`". Two things defeated that. Argument errors carried no code at
/// all: `MCPBridgeError` was a bare string, so the largest class of real
/// agent mistakes never reached the taxonomy. And `internal_error` answered
/// three unrelated questions at once: fix your request, do not retry, wait and
/// retry.
@Suite
struct ErrorTaxonomyTests {

    // MARK: Argument errors carry a code

    @Test("A refused tool call carries a code, not only a sentence")
    func bridgeErrorsCarryInvalidArguments() {
        // WRONG IMPLEMENTATION THIS DISCRIMINATES AGAINST: giving
        // `MCPBridgeError` a `code` whose default is `.internalError`, the
        // path of least resistance, since that is the code every unclassified
        // failure already used. It compiles, it type-checks, and it leaves the
        // agent exactly where it started: a refusal that says "something went
        // wrong inside Snitt" when what happened is that the agent forgot a
        // field. Verified to fail by changing the default in `MCPBridgeError`.
        //
        // Drives the REAL bridge rather than constructing errors by hand, so
        // this cannot pass while the sites that actually run still produce
        // something else.
        let badCalls: [(String, [String: Any])] = [
            ("snitt_stop_recording", [:]),                                  // missing field
            ("snitt_inspect", [:]),                                         // missing field
            ("snitt_report_input", ["sessionId": "s"]),                     // missing field
            ("snitt_start_recording", ["displayID": "not a number"]),       // wrong type
            ("snitt_start_recording", ["bundleIdentifier": "x",
                                       "microphone": "true"]),              // string boolean
            ("snitt_export", ["bundlePath": "/tmp/x.snitt",
                              "outputPath": "/tmp/x.mp4", "scale": 0]),     // non-positive scale
            ("snitt_crop", ["bundlePath": "/tmp/x.snitt", "x": 0.1]),       // incomplete rect
            ("no_such_tool", [:]),                                          // unknown tool
        ]
        for (tool, arguments) in badCalls {
            guard case .failure(let problem) =
                    MCPBridge.request(forTool: tool, arguments: arguments) else {
                Issue.record("\(tool) accepted arguments it should refuse: \(arguments)")
                continue
            }
            #expect(problem.code == .invalidArguments,
                    "\(tool) refused with \(problem.code.rawValue); an agent cannot tell a bad call from a broken Snitt unless this is invalid_arguments")
        }
    }

    @Test("A bridge refusal becomes the same value an app refusal travels in")
    func bridgeErrorsConvertToAutomationErrors() {
        // WRONG IMPLEMENTATION: a frontend that keeps two error paths, one
        // rendering `AutomationError` with its code, another rendering
        // `MCPBridgeError.message` as bare prose. That is the state this
        // decision found, and it is invisible until you compare the two
        // outputs side by side, which is what this asserts. Verified to fail
        // by making `automationError` drop the code (hardcode
        // `.internalError`).
        let problem = MCPBridgeError("snitt_stop_recording requires sessionId")
        #expect(problem.automationError.code == .invalidArguments)
        #expect(problem.automationError.message == problem.message,
                "the sentence an agent reads must not change on the way through")
    }

    @Test("A bridge site that means something else can still say so")
    func bridgeErrorCodeIsOverridable() {
        // WRONG IMPLEMENTATION: hardcoding `.invalidArguments` inside
        // `automationError` instead of defaulting the stored property, which
        // reads identically at every call site today and silently ignores the
        // first site that needs a different answer. Verified to fail by
        // hardcoding the code in `automationError`.
        let problem = MCPBridgeError("Snitt is mid-transition", code: .busy)
        #expect(problem.automationError.code == .busy)
    }

    // MARK: internal_error, split three ways

    @Test("The three answers an agent can act on are tellable apart")
    func theNewCodesAreDistinguishable() {
        // WRONG IMPLEMENTATION: adding the three cases and mapping all of them
        // to `internal_error`'s exit code 16 "so nothing breaks". Every string
        // assertion elsewhere still passes, the taxonomy looks split, and the
        // shell script §11 promises can branch is no better off than before.
        // Verified to fail by mapping all three to 16.
        let answers: [AutomationError.Code] = [.invalidArguments, .unusableRecording, .busy]
        let exits = answers.map { AutomationError.exitCode[$0] }
        #expect(exits.allSatisfy { $0 != nil }, "a code with no exit code exits 1, like everything else")
        #expect(Set(exits.compactMap { $0 }).count == answers.count,
                "fix-your-request, do-not-retry and wait-and-retry must not share a number")
        #expect(!exits.contains(AutomationError.exitCode[.internalError]),
                "the point of the split is that none of them is internal_error any more")
    }

    @Test("The exit codes that shipped keep the numbers they shipped")
    func existingExitCodesAreFrozen() {
        // WRONG IMPLEMENTATION: inserting the three new codes into the table
        // in taxonomy order and renumbering downwards, so `internal_error`
        // moves from 16 to 19. §15 makes these a public interface with agents
        // as consumers, and a renumbered table is a breaking change that no
        // other test in this repo would notice: every other assertion is about
        // codes being DISTINCT, which renumbering preserves. Verified to fail
        // by renumbering.
        #expect(AutomationError.exitCode[.consentRequired] == 10)
        #expect(AutomationError.exitCode[.upgradeRequired] == 11)
        #expect(AutomationError.exitCode[.noSuchSession] == 12)
        #expect(AutomationError.exitCode[.alreadyRecording] == 13)
        #expect(AutomationError.exitCode[.targetNotFound] == 14)
        #expect(AutomationError.exitCode[.permissionDenied] == 15)
        #expect(AutomationError.exitCode[.internalError] == 16)
    }

    // MARK: The wire

    @Test("A code from a later Snitt decodes instead of failing the whole response")
    func unknownCodesDegradeToInternalError() throws {
        // WRONG IMPLEMENTATION: the SYNTHESIZED `RawRepresentable` decoding,
        // which is what this enum had before D106. It throws `dataCorrupted`
        // on a string it does not know, so the whole `AutomationResponse`
        // fails to decode and the failure surfaces as `malformedResponse`
        // ("Snitt and snitt-mcp are out of sync") rather than as the error it
        // actually was. That makes EVERY future addition to this enum a
        // breaking change for every already-released client, and D106 adds
        // three at once. Verified to fail by deleting `Code.init(from:)`.
        //
        // The payload is deliberately a code that will never exist, not one of
        // D106's three: this is about the mechanism, and a test naming a real
        // future code would start passing for the wrong reason the day it is
        // added.
        let fromTheFuture = #"{"failure":{"_0":{"code":"a_code_from_a_later_snitt","message":"x"}}}"#
        let decoded = try JSONDecoder().decode(
            AutomationResponse.self, from: Data(fromTheFuture.utf8))
        guard case .failure(let error) = decoded else {
            Issue.record("did not decode as failure: \(decoded)"); return
        }
        #expect(error.code == .internalError,
                "an unknown code means 'something unexpected', which is what this code now means")
        #expect(error.message == "x", "the rest of the failure must survive intact")
    }

    @Test("Degrading unknown codes does not swallow the known ones")
    func knownCodesStillDecodeAsThemselves() throws {
        // The control for the test above, and it is load-bearing: an
        // `init(from:)` that returns `.internalError` unconditionally passes
        // `unknownCodesDegradeToInternalError` perfectly while collapsing the
        // entire taxonomy back into the single code D106 exists to split.
        // Verified to fail by making `init(from:)` ignore its raw value.
        for code in AutomationError.Code.allCases {
            let payload = #"{"failure":{"_0":{"code":"\#(code.rawValue)","message":"x"}}}"#
            let decoded = try JSONDecoder().decode(
                AutomationResponse.self, from: Data(payload.utf8))
            guard case .failure(let error) = decoded else {
                Issue.record("did not decode as failure: \(decoded)"); continue
            }
            #expect(error.code == code, "\(code.rawValue) decoded as \(error.code.rawValue)")
        }
    }

    @Test("An old app's internal_error still decodes, unchanged")
    func theCodeBeingSplitStillRoundTrips() throws {
        // The compatibility direction D106 must not break: a Snitt that
        // predates the split sends `internal_error` for every one of these
        // failures, and a client built after it must read that as it always
        // did rather than as something new.
        //
        // WRONG IMPLEMENTATION: renaming `internalError`'s raw string while
        // adding the new ones (say to "unexpected_error", which reads better
        // beside the three). `Code`'s own doc comment calls renaming a
        // breaking protocol change, and the lenient decoder above would now
        // HIDE it on the way IN: an old payload's "internal_error" is no
        // longer a known raw value, so it lands on `.internalError` by the
        // fallback and the decode assertion below still passes. Verified: with
        // the raw value renamed, both decoding tests above stay green and only
        // the ENCODE assertion at the end of this test fails, which is why
        // this test asserts both directions rather than only the readable one.
        let old = #"{"failure":{"_0":{"code":"internal_error","message":"boom","hint":"why"}}}"#
        let decoded = try JSONDecoder().decode(AutomationResponse.self, from: Data(old.utf8))
        #expect(decoded == .failure(AutomationError(
            code: .internalError, message: "boom", hint: "why")))

        // And the reverse: what this Snitt writes for that code is byte-wise
        // what the old one wrote, so an old client reading a new app's
        // internal_error is unaffected too.
        let encoded = try JSONEncoder().encode(AutomationError(code: .internalError, message: "boom"))
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(object?["code"] as? String == "internal_error")
    }
}
