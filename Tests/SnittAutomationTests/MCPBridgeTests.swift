// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittAutomation

/// Decodes MCP tool arguments from real JSON text, the same way `snitt-mcp`'s
/// stdio loop does (`JSONSerialization.jsonObject`, `Sources/snitt-mcp/main.swift`).
///
/// A Swift dictionary literal like `["scale": 1]` boxes a native `Int` in
/// `Any`; `JSONSerialization` never produces that — it always produces
/// `NSNumber`. The two are not interchangeable for a check like `value is
/// Bool`, which succeeds for an `NSNumber` holding exactly 0 or 1 but not for
/// a native `Int`. A test built from a Swift literal cannot see that
/// distinction and can pass while the shipped binary is broken — which is
/// exactly what happened here. Every fixture in this file goes through real
/// JSON decoding so the type reaching `MCPBridge.request` is the type
/// production actually reaches it with.
func jsonArguments(_ json: String) -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    else {
        Issue.record("test fixture is not valid JSON: \(json)")
        return [:]
    }
    return object
}

@Test("Every advertised tool maps to a request — none is decorative")
func everyToolMaps() {
    for tool in MCPBridge.toolDefinitions() {
        let json: String
        switch tool.name {
        case "snitt_start_recording":
            json = #"{"bundleIdentifier": "com.apple.Safari"}"#
        case "snitt_stop_recording", "snitt_mark",
             "snitt_pause_recording", "snitt_resume_recording", "snitt_screenshot":
            json = #"{"sessionId": "abc"}"#
        case "snitt_inspect", "snitt_transcript":
            json = #"{"bundlePath": "/tmp/x.snitt"}"#
        case "snitt_narrate":
            json = #"{"bundlePath": "/tmp/x.snitt", "text": "a line", "atSeconds": 1}"#
        case "snitt_report_input":
            json = #"{"bundlePath": "", "sessionId": "abc", "kind": "click", "x": 0.5, "y": 0.5}"#
        case "snitt_crop":
            json = #"{"bundlePath": "/tmp/x.snitt", "reset": true}"#
        case "snitt_trim":
            json = #"{"bundlePath": "/tmp/x.snitt", "autoTrim": true}"#
        case "snitt_estimate":
            json = #"{"bundlePath": "/tmp/x.snitt"}"#
        case "snitt_auto_deep_trim":
            // Deliberately the MINIMAL call: everything but the path is
            // optional, and if that ever stops being true this is where it
            // shows up.
            json = #"{"bundlePath": "/tmp/x.snitt"}"#
        case "snitt_export":
            json = #"{"bundlePath": "/tmp/x.snitt", "format": "mp4", "outputPath": "/tmp/demo.mp4"}"#
        case "snitt_diagnostics_export":
            json = #"{"outputPath": "/tmp/diagnostics.json"}"#
        case "snitt_list_recordings":
            json = "{}"
        default:
            json = "{}"
        }
        let mapped = MCPBridge.request(forTool: tool.name, arguments: jsonArguments(json))
        guard case .success = mapped else {
            Issue.record("advertised tool \(tool.name) does not map to a request"); return
        }
    }
}

@Test("Tool names are the agent-facing contract and must not drift")
func toolNamesAreStable() {
    let names = Set(MCPBridge.toolDefinitions().map(\.name))
    #expect(names == ["snitt_list_targets", "snitt_start_recording",
                      "snitt_stop_recording", "snitt_status", "snitt_mark",
                      "snitt_inspect", "snitt_trim", "snitt_crop", "snitt_export",
                      "snitt_auto_deep_trim", "snitt_estimate",
                      "snitt_pause_recording", "snitt_resume_recording",
                      "snitt_screenshot", "snitt_report_input",
                      "snitt_diagnostics_export",
                      "snitt_transcript", "snitt_narrate",
                      "snitt_list_recordings"])
}

@Test("The MCP tool maps to the same request the CLI would send")
func mcpDiagnosticsMapsToTheSameRequest() {
    // §4.8: the CLI and the MCP server must be incapable of diverging.
    // Fixture decoded from real JSON text, as every fixture in this file
    // is — see `jsonArguments`'s doc comment.
    guard case .success(let mcpBody) = MCPBridge.request(
        forTool: "snitt_diagnostics_export",
        arguments: jsonArguments(#"{"outputPath": "/tmp/diagnostics.json"}"#))
    else { Issue.record("MCP could not express a diagnostics export"); return }
    guard case .diagnostics(let mcpPath) = mcpBody else {
        Issue.record("expected .diagnostics, got \(mcpBody)"); return
    }
    // The discriminating assertion: the request body actually CARRIES the
    // path, not merely that mapping the tool call "succeeded" — a bridge
    // that mapped every tool call to `.diagnostics(outputPath: "")` would
    // pass a success-only assertion.
    #expect(mcpPath == "/tmp/diagnostics.json")
}

// The three tests below inject an explicit `workingDirectory` — the same
// injectable seam `snitt-cli`'s own `requestBody(for:currentDirectory:)`
// uses — rather than `chdir`-ing the real process. `chdir` mutates
// process-wide, shared state: swift-testing runs every test target in ONE
// process (`SnittPackageTests.xctest`) and parallelizes across ALL of them by
// default, not just within this file, so a `chdir` here can race unrelated
// tests elsewhere in the package that resolve their own paths against the
// real cwd (several such tests exist under `SnittAppTests`) — serializing
// only this file's tests against each other narrows that race without
// closing it. Asserting through `workingDirectory` instead removes the
// shared mutable state entirely: the real process cwd is never touched and
// is irrelevant to these tests.
@Test("snitt_diagnostics_export resolves a relative outputPath against the caller's working directory")
func diagnosticsExportResolvesRelativePaths() {
    // `.diagnostics`'s own doc comment (`Protocol.swift`) declares
    // `outputPath` arrives already resolved against the CALLER's working
    // directory. `snitt-cli` honours that via `PathResolver.resolve` before
    // it ever builds the request; `MCPBridge.request` — the only place
    // `snitt-mcp` builds one — forwarded the raw string instead, so a
    // relative path from an MCP client would resolve wherever
    // `AutomationHost`/`Snitt.app` happened to have its cwd, not the
    // caller's, exactly the M3c finding #3 shape this file's `PathResolver`
    // doc comment describes for `bundlePath`/`outputPath` generally.
    //
    // A fixed absolute path (as every other fixture in this file uses)
    // cannot tell a resolving implementation from a pass-through one — both
    // leave it unchanged. Only a RELATIVE path discriminates.
    let workingDirectory = "/private/tmp/MCPBridgeTests-\(UUID().uuidString)"

    guard case .success(let body) = MCPBridge.request(
        forTool: "snitt_diagnostics_export",
        arguments: jsonArguments(#"{"outputPath": "diagnostics.json"}"#),
        workingDirectory: workingDirectory)
    else { Issue.record("MCP could not express a diagnostics export"); return }
    guard case .diagnostics(let resolvedPath) = body else {
        Issue.record("expected .diagnostics, got \(body)"); return
    }

    #expect(resolvedPath == workingDirectory + "/diagnostics.json",
            "a relative outputPath must resolve against the caller's working directory, not arrive verbatim")
}

@Test("snitt_trim resolves a relative bundlePath against the caller's working directory")
func trimResolvesRelativePaths() {
    // Same shape as `diagnosticsExportResolvesRelativePaths` above: only
    // a relative path discriminates a resolving implementation from a
    // pass-through one.
    let workingDirectory = "/private/tmp/MCPBridgeTests-\(UUID().uuidString)"

    guard case .success(let body) = MCPBridge.request(
        forTool: "snitt_trim",
        arguments: jsonArguments(#"{"bundlePath": "d.snitt", "autoTrim": true}"#),
        workingDirectory: workingDirectory)
    else { Issue.record("MCP could not express a trim"); return }
    guard case .trim(let resolvedPath, _, _, _) = body else {
        Issue.record("expected .trim, got \(body)"); return
    }

    #expect(resolvedPath == workingDirectory + "/d.snitt",
            "a relative bundlePath must resolve against the caller's working directory, not arrive verbatim")
}

@Test("snitt_export resolves relative bundlePath and outputPath against the caller's working directory")
func exportResolvesRelativePaths() {
    let workingDirectory = "/private/tmp/MCPBridgeTests-\(UUID().uuidString)"

    guard case .success(let body) = MCPBridge.request(
        forTool: "snitt_export",
        arguments: jsonArguments(#"{"bundlePath": "d.snitt", "format": "mp4", "outputPath": "out.mp4"}"#),
        workingDirectory: workingDirectory)
    else { Issue.record("MCP could not express an export"); return }
    guard case .export(let resolvedBundlePath, _, let resolvedOutputPath, _, _, _, _, _, _, _, _) = body else {
        Issue.record("expected .export, got \(body)"); return
    }

    #expect(resolvedBundlePath == workingDirectory + "/d.snitt",
            "a relative bundlePath must resolve against the caller's working directory, not arrive verbatim")
    #expect(resolvedOutputPath == workingDirectory + "/out.mp4",
            "a relative outputPath must resolve against the caller's working directory, not arrive verbatim")
}

@Test("snitt_diagnostics_export requires outputPath")
func diagnosticsExportRequiresOutputPath() {
    guard case .failure(let error) = MCPBridge.request(
        forTool: "snitt_diagnostics_export", arguments: jsonArguments("{}"))
    else { Issue.record("a missing outputPath must be refused"); return }
    #expect(error.message.contains("outputPath"))
}

@Test("Both frontends express a trim identically")
func frontendsAgreeOnTrim() {
    guard case .success(let cliCommand) =
        CommandLineParser.parse(["trim", "/tmp/d.snitt", "--start", "1", "--end", "9"])
    else { Issue.record("CLI could not express a trim"); return }
    guard case .trim(let cliPath, let cliStart, let cliEnd, let cliAuto) = cliCommand else {
        Issue.record("expected a trim command, got \(cliCommand)"); return
    }
    // Mirrors the mapping in Sources/snitt-cli/main.swift's switch over
    // ParsedCommand, so this test exercises that mapping too — not only the
    // parser — and would catch a future change that made the two diverge.
    let cliBody = AutomationRequest.Body.trim(bundlePath: cliPath, start: cliStart,
                                               end: cliEnd, auto: cliAuto)

    guard case .success(let mcpBody) = MCPBridge.request(
        forTool: "snitt_trim",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/d.snitt", "start": 1, "end": 9}"#))
    else { Issue.record("MCP could not express a trim"); return }

    guard case .trim(let cliBPath, let cliBStart, let cliBEnd, let cliBAuto) = cliBody else {
        Issue.record("CLI body is not .trim"); return
    }
    guard case .trim(let mcpPath, let mcpStart, let mcpEnd, let mcpAuto) = mcpBody else {
        Issue.record("MCP body is not .trim"); return
    }
    #expect(cliBPath == mcpPath)
    #expect(cliBStart == mcpStart)
    #expect(cliBEnd == mcpEnd)
    #expect(cliBAuto == mcpAuto)
}

@Test("A non-numeric scale is refused, not silently defaulted to full scale")
func nonNumericScaleRefused() {
    // A plausible wrong implementation: numericValue returns nil for a
    // string, and the caller treats nil as "absent" and falls back to the
    // default 1.0 — silently exporting at full scale while reporting
    // success, when the caller asked for half scale. §8 forbids exactly
    // this: a confidently-wrong result.
    guard case .failure(let error) = MCPBridge.request(
        forTool: "snitt_export",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "format": "mp4","#
            + #""outputPath": "/tmp/demo.mp4", "scale": "0.5"}"#))
    else { Issue.record("a string scale must not be silently accepted"); return }
    #expect(error.message.contains("scale"))
}

@Test("A real JSON boolean start does not silently fall through while a valid end sails through")
func nonNumericStartRefusedEvenWithValidEnd() {
    // A plausible wrong implementation: numericValue correctly rejects the
    // bool for `start` by returning nil, but the caller cannot distinguish
    // that from "start absent" — so the guard (auto || start != nil || end
    // != nil) is satisfied by the valid `end`, and a DIFFERENT trim than the
    // one requested goes out with no error at all.
    guard case .failure(let error) = MCPBridge.request(
        forTool: "snitt_trim",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "start": true, "end": 9}"#))
    else { Issue.record("a boolean start must not be silently dropped"); return }
    #expect(error.message.contains("start"))
}

@Test("An integer scale of exactly 1, decoded from real JSON, is accepted — not misread as a boolean")
func integerScaleOfOneAcceptedFromRealJSON() {
    // Regression test. `JSONSerialization` decodes every JSON number —
    // including a plain integer like `1` — to `NSNumber`. A discriminator
    // written as `value is Bool` succeeds for an `NSNumber` holding exactly
    // 0 or 1 regardless of whether it came from a JSON boolean or a JSON
    // integer, so it rejected the single most common scale an agent sends.
    // A Swift dictionary literal `["scale": 1]` cannot reproduce this: it
    // boxes a native Int, which `is Bool` never misclassifies. Only a
    // JSON-decoded fixture can catch this.
    let mapped = MCPBridge.request(
        forTool: "snitt_export",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "format": "mp4","#
            + #""outputPath": "/tmp/demo.mp4", "scale": 1}"#))
    guard case .success(.export(_, _, _, let scale, _, _, _, _, _, _, _)) = mapped else {
        Issue.record("scale: 1, decoded from JSON, must be accepted as a number"); return
    }
    #expect(scale == 1.0)
}

@Test("start/end of exactly 0 and 1, decoded from real JSON, are accepted — not misread as booleans")
func integerBoundsOfZeroAndOneAcceptedFromRealJSON() {
    let mapped = MCPBridge.request(
        forTool: "snitt_trim",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "start": 0, "end": 1}"#))
    guard case .success(.trim(_, let start, let end, _)) = mapped else {
        Issue.record("start: 0, end: 1, decoded from JSON, must be accepted as numbers"); return
    }
    #expect(start == 0.0)
    #expect(end == 1.0)
}

@Test("A real JSON boolean scale is still refused")
func realJSONBooleanScaleRefused() {
    // The flip side of the regression fix: a genuine JSON `true` must still
    // be rejected, not accidentally accepted as `1.0` now that plain
    // integers are let through.
    guard case .failure(let error) = MCPBridge.request(
        forTool: "snitt_export",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "format": "mp4","#
            + #""outputPath": "/tmp/demo.mp4", "scale": true}"#))
    else { Issue.record("a real JSON boolean scale must not be accepted"); return }
    #expect(error.message.contains("scale"))
}

@Test("snitt_export rejects a zero or negative scale")
func mcpExportRejectsNonPositiveScale() {
    guard case .failure = MCPBridge.request(
        forTool: "snitt_export",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "format": "mp4","#
            + #""outputPath": "/tmp/demo.mp4", "scale": 0}"#))
    else { Issue.record("a zero scale must not be silently accepted"); return }
    guard case .failure = MCPBridge.request(
        forTool: "snitt_export",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "format": "mp4","#
            + #""outputPath": "/tmp/demo.mp4", "scale": -0.5}"#))
    else { Issue.record("a negative scale must not be silently accepted"); return }
}

@Test("snitt_trim rejects an end at or before start")
func mcpTrimRejectsInvertedRange() {
    guard case .failure = MCPBridge.request(
        forTool: "snitt_trim",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "start": 9, "end": 5}"#))
    else { Issue.record("an inverted range must not be silently accepted"); return }
    guard case .failure = MCPBridge.request(
        forTool: "snitt_trim",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "start": 5, "end": 5}"#))
    else { Issue.record("an empty range must not be silently accepted"); return }
}

@Test("Both frontends express a marker identically")
func frontendsAgreeOnMarkers() {
    // §4.8: the CLI and the MCP server must be incapable of diverging.
    guard case .success(.recordMark(let cliSession, let cliLabel)) =
        CommandLineParser.parse(["record", "mark", "s1", "--label", "step two"]) else {
        Issue.record("CLI could not express a marker"); return
    }
    guard case .success(.mark(let mcpSession, let mcpLabel)) = MCPBridge.request(
        forTool: "snitt_mark",
        arguments: jsonArguments(#"{"sessionId": "s1", "label": "step two"}"#)) else {
        Issue.record("MCP could not express a marker"); return
    }
    #expect(cliSession == mcpSession)
    #expect(cliLabel == mcpLabel)
}

@Test("Both frontends express an inspect identically")
func frontendsAgreeOnInspect() {
    // §4.8: the CLI and the MCP server must be incapable of diverging.
    guard case .success(.inspect(let cliPath)) =
        CommandLineParser.parse(["inspect", "/tmp/demo.snitt"]) else {
        Issue.record("CLI could not express an inspect"); return
    }
    guard case .success(.inspect(let mcpPath)) = MCPBridge.request(
        forTool: "snitt_inspect",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/demo.snitt"}"#)) else {
        Issue.record("MCP could not express an inspect"); return
    }
    #expect(cliPath == mcpPath)
}

@Test("Starting a recording without a target is refused before it reaches the app")
func startNeedsATarget() {
    let mapped = MCPBridge.request(forTool: "snitt_start_recording", arguments: jsonArguments("{}"))
    guard case .failure(let error) = mapped else {
        Issue.record("a targetless start must not be sent"); return
    }
    #expect(error.message.contains("bundleIdentifier"))
}

@Test("An unknown tool is refused rather than silently ignored")
func unknownToolRefused() {
    guard case .failure = MCPBridge.request(forTool: "snitt_do_magic", arguments: jsonArguments("{}"))
    else {
        Issue.record("unknown tools must fail"); return
    }
}

@Test("The MCP microphone default matches the CLI's — off")
func micDefaultMatchesCLI() {
    guard case .success(.startRecording(let options)) = MCPBridge.request(
        forTool: "snitt_start_recording",
        arguments: jsonArguments(#"{"bundleIdentifier": "com.apple.Safari"}"#)) else {
        Issue.record("mapping failed"); return
    }
    // §4.8: the two frontends must not diverge. This is the cheapest place for
    // them to drift, so it is asserted directly.
    #expect(options.microphone == false)
    #expect(options.systemAudio == true)
}

@Test("Both frontends can express the same set of targets")
func frontendsAgreeOnTargets() {
    // §4.8: the CLI and the MCP server must be incapable of diverging. An
    // operation reachable from one and not the other is that divergence, and
    // this is where it silently appeared once already.
    guard case .success(.recordStart(let cliDisplay)) =
        CommandLineParser.parse(["record", "start", "--display", "7"]) else {
        Issue.record("CLI could not express a display target"); return
    }
    guard case .success(.startRecording(let mcpDisplay)) = MCPBridge.request(
        forTool: "snitt_start_recording",
        arguments: jsonArguments(#"{"displayID": 7}"#)) else {
        Issue.record("MCP could not express a display target"); return
    }
    #expect(cliDisplay.displayID == mcpDisplay.displayID)
    #expect(cliDisplay.displayID == 7)
}

@Test("A non-integral displayID is refused rather than silently truncated")
func nonIntegralDisplayIDRefused() {
    guard case .failure(let error) = MCPBridge.request(
        forTool: "snitt_start_recording",
        arguments: jsonArguments(#"{"displayID": 7.5}"#)) else {
        Issue.record("a fractional displayID must not be sent"); return
    }
    #expect(error.message.contains("displayID"))
}

@Test("An out-of-range displayID is refused rather than silently truncated")
func outOfRangeDisplayIDRefused() {
    guard case .failure(let error) = MCPBridge.request(
        forTool: "snitt_start_recording",
        arguments: jsonArguments(#"{"displayID": -1}"#)) else {
        Issue.record("a negative displayID must not be sent"); return
    }
    #expect(error.message.contains("displayID"))
}

@Test("A string \"true\" for autoTrim is refused, not silently ignored in favor of a plain range trim")
func stringAutoTrimRefused() {
    // Discriminates against `arguments["autoTrim"] as? Bool ?? false`: a JSON
    // string decodes to `NSString`, which `as? Bool` fails on, so this value
    // was silently swallowed into the `false` default. `start` is included
    // here specifically so the old buggy path does not ALSO fail the
    // "needs either start/end or autoTrim" guard for an unrelated reason —
    // with a valid `start` present, the bug's actual failure mode is a
    // silent SUCCESS mapping to a plain range trim, not the auto-trim the
    // caller asked for. A test without `start` here would pass against the
    // old code too, for the wrong reason (the guard rejects it either way),
    // and prove nothing about the boolean discipline.
    guard case .failure(let error) = MCPBridge.request(
        forTool: "snitt_trim",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "start": 1, "autoTrim": "true"}"#))
    else { Issue.record("a string autoTrim must not be silently accepted as a plain range trim"); return }
    #expect(error.message.contains("autoTrim"))
}

@Test("A string \"true\" for chapters is refused, not silently read as absent")
func stringChaptersRefused() {
    // Same defect, the other reported instance: `{"chapters": "true"}` used
    // to export successfully with chapters: false, chaptersPath: nil — a
    // manifest indistinguishable from a recording with no markers at all,
    // reported as success.
    guard case .failure(let error) = MCPBridge.request(
        forTool: "snitt_export",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "format": "mp4","#
            + #""outputPath": "/tmp/demo.mp4", "chapters": "true"}"#))
    else { Issue.record("a string chapters must not be silently accepted"); return }
    #expect(error.message.contains("chapters"))
}

@Test("chapters: 1, decoded from real JSON, is accepted as true — numeric leniency is kept")
func numericChaptersOneAcceptedAsTrue() {
    // The flip side of the string-rejection fix: `numericValue` already
    // treats a JSON integer 0/1 as a legitimate number rather than a stray
    // boolean, and booleans must extend the SAME leniency the other way —
    // `chapters: 1` must keep reading as `true`, not be swept up by the
    // stricter string handling and refused too.
    let mapped = MCPBridge.request(
        forTool: "snitt_export",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "format": "mp4","#
            + #""outputPath": "/tmp/demo.mp4", "chapters": 1}"#))
    guard case .success(.export(_, _, _, _, let chapters, _, _, _, _, _, _)) = mapped else {
        Issue.record("chapters: 1, decoded from JSON, must be accepted as true"); return
    }
    #expect(chapters == true)
}

@Test("snitt_export accepts gif and a string maxSize")
func mcpAcceptsGifAndMaxSize() {
    let args = jsonArguments("""
    {"bundlePath":"/tmp/b.snitt","format":"gif","outputPath":"/tmp/o.gif","maxSize":"5MB"}
    """)
    guard case .success(let request) = MCPBridge.request(forTool: "snitt_export", arguments: args),
          case .export(_, let format, _, _, _, _, let maxSize, _, _, _, _) = request else {
        Issue.record("expected a successful export request"); return
    }
    #expect(format == "gif")
    #expect(maxSize == 5_000_000)
}

@Test("A malformed maxSize fails the call by name rather than exporting unbounded")
func mcpMalformedMaxSizeFails() {
    let args = jsonArguments("""
    {"bundlePath":"/tmp/b.snitt","format":"mp4","outputPath":"/tmp/o.mp4","maxSize":"lots"}
    """)
    guard case .failure(let error) = MCPBridge.request(forTool: "snitt_export", arguments: args) else {
        Issue.record("expected failure"); return
    }
    #expect(error.message.contains("maxSize"))
}

@Test("An absent maxSize means no limit, not a zero limit")
func mcpAbsentMaxSizeIsNoLimit() {
    let args = jsonArguments("""
    {"bundlePath":"/tmp/b.snitt","format":"mp4","outputPath":"/tmp/o.mp4"}
    """)
    guard case .success(let request) = MCPBridge.request(forTool: "snitt_export", arguments: args),
          case .export(_, _, _, _, _, _, let maxSize, _, _, _, _) = request else {
        Issue.record("expected success"); return
    }
    // A `?? 0` default would make every export target zero bytes and walk
    // the whole ladder before reporting a miss.
    #expect(maxSize == nil)
}

@Test("autoTrim: true, decoded from real JSON, is still accepted")
func realJSONBooleanAutoTrimAccepted() {
    let mapped = MCPBridge.request(
        forTool: "snitt_trim",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "autoTrim": true}"#))
    guard case .success(.trim(_, _, _, let auto)) = mapped else {
        Issue.record("autoTrim: true, decoded from JSON, must be accepted"); return
    }
    #expect(auto == true)
}

@Test("A displayID of exactly 1, decoded from real JSON, is accepted — not misread as a boolean")
func displayIDOfOneAcceptedFromRealJSON() {
    // Same regression class as the scale/start/end fix, applied to
    // `displayID(from:)`, which used the same `is Bool` discriminator.
    guard case .success(.startRecording(let options)) = MCPBridge.request(
        forTool: "snitt_start_recording",
        arguments: jsonArguments(#"{"displayID": 1}"#)) else {
        Issue.record("displayID: 1, decoded from JSON, must be accepted as a number"); return
    }
    #expect(options.displayID == 1)
}

@Test("When both a window and a display are given, MCP agrees with ConsentPolicy's precedence")
func displayTakesPrecedenceOverBundleIdentifier() {
    // ConsentPolicy.evaluate checks displayID before bundleIdentifier and
    // returns as soon as a display request is permitted, never consulting
    // bundleIdentifier at all. MCPBridge must map the same way, or the two
    // could disagree about which target a request that carries both actually
    // names.
    guard case .success(.startRecording(let options)) = MCPBridge.request(
        forTool: "snitt_start_recording",
        arguments: jsonArguments(#"{"bundleIdentifier": "com.apple.Safari", "displayID": 7}"#)) else {
        Issue.record("mapping failed"); return
    }
    #expect(options.displayID == 7)
}

@Test("A string \"true\" for subtitles is refused, not silently read as absent")
func stringSubtitlesRefused() {
    // The third instance of the same defect. `chapters` and `clicks` on this
    // very tool were routed through `booleanValue`; `subtitles` was left on
    // `arguments["subtitles"] as? Bool ?? false`, so a JSON string decoded to
    // NSString, failed the cast, and fell into the `false` default. The export
    // then succeeded with no `.subtitles.vtt` written and nothing to
    // distinguish that from a caller who genuinely passed false.
    //
    // Discriminates against the bare-cast implementation: that version returns
    // .success here, because the bad value is swallowed rather than refused.
    guard case .failure(let error) = MCPBridge.request(
        forTool: "snitt_export",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "format": "mp4","#
            + #""outputPath": "/tmp/demo.mp4", "subtitles": "true"}"#))
    else { Issue.record("a string subtitles must not be silently accepted"); return }
    #expect(error.message.contains("subtitles"))
}

@Test("subtitles: 1, decoded from real JSON, is accepted as true")
func numericSubtitlesOneAcceptedAsTrue() {
    // The flip side, matching `numericChaptersOneAcceptedAsTrue`: routing
    // `subtitles` through `booleanValue` must extend the same numeric leniency
    // its siblings get, not tighten it into a refusal.
    let mapped = MCPBridge.request(
        forTool: "snitt_export",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "format": "mp4","#
            + #""outputPath": "/tmp/demo.mp4", "subtitles": 1}"#))
    guard case .success(.export(_, _, _, _, _, let subtitles, _, _, _, _, _)) = mapped else {
        Issue.record("subtitles: 1, decoded from JSON, must be accepted as true"); return
    }
    #expect(subtitles == true)
}

@Test("An MCP recording carries the working directory, so it gets git context")
func startRecordingCarriesWorkingDirectory() {
    // `StartOptions.workingDirectory` is what §7's git context is discovered
    // from, and its doc comment says it is "filled by the CLI, not the app"
    // because Snitt.app's own directory is `/`. The CLI fills it on every
    // `record start`; the MCP bridge received a workingDirectory argument,
    // used it to resolve bundle and output paths for five other tools, and
    // never put it on StartOptions — so every agent-driven recording over MCP
    // was filed with no git context at all, silently.
    //
    // Discriminates against the version that omits the assignment: there,
    // `options.workingDirectory` is nil and this expectation fails while every
    // other start-recording test still passes.
    guard case .success(.startRecording(let options)) = MCPBridge.request(
        forTool: "snitt_start_recording",
        arguments: jsonArguments(#"{"bundleIdentifier": "com.apple.Safari"}"#),
        workingDirectory: "/Users/someone/src/project") else {
        Issue.record("mapping failed"); return
    }
    #expect(options.workingDirectory == "/Users/someone/src/project")
}

@Test("A string \"true\" for reset is refused, not silently swallowed into applying a crop")
func stringCropResetRefused() {
    // The FOURTH instance of this defect, found by enumerating the class
    // rather than waiting for a report. `reset` used `as? Bool == true`, so a
    // JSON string fell through to the rect branch.
    //
    // The rect is present here for the same reason `start` is present in
    // `stringAutoTrimRefused`: without it the old code fails anyway on the
    // "all four or none" guard, and the test would pass against the bug for
    // the wrong reason. WITH a rect, the old code's real failure mode shows —
    // a silent SUCCESS that APPLIES a crop to a caller who asked to remove one.
    guard case .failure(let error) = MCPBridge.request(
        forTool: "snitt_crop",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "reset": "true","#
            + #""x": 0, "y": 0, "width": 0.5, "height": 0.5}"#))
    else { Issue.record("a string reset must not be silently swallowed"); return }
    #expect(error.message.contains("reset"))
}

/// Minimal arguments that make each tool's request VALID, so adding one bad
/// boolean is the only reason a call can fail.
private let booleanGuardFixtures: [String: String] = [
    "snitt_start_recording": #"{"bundleIdentifier": "com.apple.Safari"}"#,
    // `start` present so an unrelated guard cannot be what refuses the call.
    "snitt_trim": #"{"bundlePath": "/tmp/x.snitt", "start": 1}"#,
    // A full rect, for the reason spelled out in `stringCropResetRefused`.
    "snitt_crop": #"{"bundlePath": "/tmp/x.snitt", "x": 0, "y": 0, "width": 0.5, "height": 0.5}"#,
    "snitt_export": #"{"bundlePath": "/tmp/x.snitt", "format": "mp4", "outputPath": "/tmp/d.mp4"}"#,
    "snitt_screenshot": #"{"sessionId": "abc123"}"#,
    "snitt_auto_deep_trim": #"{"bundlePath": "/tmp/x.snitt"}"#,
]

@Test("EVERY boolean parameter on EVERY tool refuses a JSON string")
func everyBooleanParameterRefusesAString() {
    // The structural guard. Four separate rounds of one bug reached shipped
    // code — `numericValue`/`displayID`, then `autoTrim`/`chapters`, then
    // `subtitles`, then `crop`'s `reset` — because each was fixed as an
    // instance. Fixing instances is what let the next one through.
    //
    // This walks the tool definitions themselves, so a boolean added later is
    // covered the day it is added rather than the day someone reports it. If a
    // new tool grows a boolean, this fails until a fixture is supplied, which
    // is the point: the failure is a prompt, not an obstacle.
    var checked = 0
    for tool in MCPBridge.toolDefinitions() {
        guard let properties = tool.inputSchema["properties"] as? [String: Any] else { continue }
        for (parameter, spec) in properties {
            guard let spec = spec as? [String: Any],
                  spec["type"] as? String == "boolean" else { continue }
            guard let fixture = booleanGuardFixtures[tool.name] else {
                Issue.record("""
                    \(tool.name) has a boolean parameter "\(parameter)" but no fixture in \
                    booleanGuardFixtures. Add minimal valid arguments for it so this guard \
                    can prove the parameter refuses a JSON string.
                    """)
                continue
            }
            var arguments = jsonArguments(fixture)
            arguments[parameter] = "true"
            guard case .failure(let error) = MCPBridge.request(
                forTool: tool.name, arguments: arguments) else {
                Issue.record("""
                    \(tool.name) accepted the JSON STRING "true" for "\(parameter)" instead of \
                    refusing it. That is the silent-default bug: the value is swallowed and the \
                    call succeeds having ignored what the caller asked for.
                    """)
                continue
            }
            #expect(error.message.contains(parameter),
                    "the refusal must name the parameter so a caller can fix it")
            checked += 1
        }
    }
    // Guards the guard: a refactor that stopped finding boolean properties
    // would otherwise make this test vacuously pass.
    #expect(checked >= 7, "expected at least 7 boolean parameters across the tool surface")
}


@Test("snitt_screenshot does not return the frame unless asked")
func inlineScreenshotIsOptIn() {
    // A9: returning pixels makes "screen content leaves this machine" the
    // default rather than the caller's choice, and an MCP host is usually a
    // cloud model. `screenshotForAgent` already calls a screenshot "the most
    // obviously sensitive thing this surface could hand out" and puts that on
    // Snitt rather than the caller; §5.6 makes input rendering opt-in for the
    // same reason.
    //
    // Discriminates against defaulting `inline` to true, which would send the
    // frame on every call an agent makes without ever saying so.
    guard case .success(.screenshot(_, _, let inline)) = MCPBridge.request(
        forTool: "snitt_screenshot",
        arguments: jsonArguments(#"{"sessionId": "abc123"}"#)) else {
        Issue.record("mapping failed"); return
    }
    #expect(inline == false)
}

@Test("snitt_screenshot returns the frame when inline is asked for")
func inlineScreenshotHonoursTheFlag() {
    guard case .success(.screenshot(_, _, let inline)) = MCPBridge.request(
        forTool: "snitt_screenshot",
        arguments: jsonArguments(#"{"sessionId": "abc123", "inline": true}"#)) else {
        Issue.record("mapping failed"); return
    }
    #expect(inline == true)
}

// MARK: - Renames, and the compatibility that makes them safe (PR G)

@Test("The renamed tools still answer to the names they were advertised under")
func oldToolNamesStillMap() {
    // An MCP host caches the tool list it was handed at `initialize` and may go
    // on calling the old name for the life of that session, while a `tools/list`
    // a moment later advertises the new one. Discriminates against renaming the
    // switch cases and nothing else, which is how a rename usually ships:
    // `snitt_add_marker` would then fall to `default` and be refused as an
    // unknown tool, on a session that was told that name by this very server.
    guard case .success(.mark(let session, _)) = MCPBridge.request(
        forTool: "snitt_add_marker",
        arguments: jsonArguments(#"{"sessionId": "s1", "label": "step two"}"#)) else {
        Issue.record("snitt_add_marker no longer maps"); return
    }
    #expect(session == "s1")
    guard case .success(.estimateExport(let path, _, _)) = MCPBridge.request(
        forTool: "snitt_estimate_export",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt"}"#)) else {
        Issue.record("snitt_estimate_export no longer maps"); return
    }
    #expect(path == "/tmp/x.snitt")
}

@Test("The old names are accepted but not advertised, so a fresh reader sees one name per verb")
func oldToolNamesAreNotAdvertised() {
    // The other half of the alias, and the reason `toolNamesAreStable` is not
    // enough on its own: an implementation that simply ADDED the new names to
    // the list would pass every mapping test above while handing agents
    // sixteen verbs under eighteen names, which is the confusion the rename
    // exists to remove.
    let advertised = Set(MCPBridge.toolDefinitions().map(\.name))
    for old in MCPBridge.toolAliases.keys {
        #expect(!advertised.contains(old), "\(old) is still advertised")
    }
    #expect(MCPBridge.toolAliases.count == 2)
}

@Test("snitt_estimate refuses a format it cannot estimate, rather than answering about mp4")
func estimateRefusesGif() {
    // The MCP tool declared no `format` at all and hardcoded "mp4", so
    // {"format": "gif"} came back as an mp4 estimate, a confident answer to a
    // question nobody asked (§8), and the CLI already refuses the same request
    // in the same words. Discriminates against the hardcoding: that version
    // returns .success here.
    guard case .failure(let error) = MCPBridge.request(
        forTool: "snitt_estimate",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "format": "gif"}"#))
    else { Issue.record("a gif estimate must be refused, not answered about mp4"); return }
    #expect(error.message.contains("mp4"))
    // And the CLI's refusal says the same thing, because a caller must not be
    // told yes by one frontend and no by the other.
    guard case .failure(let cli) = CommandLineParser.parse(
        ["estimate", "/tmp/x.snitt", "--format", "gif"]) else {
        Issue.record("the CLI accepted a gif estimate"); return
    }
    #expect(cli.message.contains("how much the picture moves"))
    #expect(error.message.contains("how much the picture moves"))
}

// MARK: - Defaults (PR G, PR I)

@Test("Reported clicks are drawn unless the caller says otherwise, on both frontends")
func clicksDefaultToOn() {
    // D105. Discriminates against `booleanValue(...) ?? false`, which is what
    // shipped: the loop's own instructions tell an agent to report every input
    // BECAUSE a demo with invisible causes is unwatchable, and then the export
    // drew none of it unless asked a second time. Only clicks that were
    // REPORTED can be drawn, so this default cannot surface anything the caller
    // did not itself hand over.
    guard case .success(.export(_, _, _, _, _, _, _, _, let mcpClicks, _, _)) = MCPBridge.request(
        forTool: "snitt_export",
        arguments: jsonArguments(
            #"{"bundlePath": "/tmp/x.snitt", "format": "mp4", "outputPath": "/tmp/d.mp4"}"#))
    else { Issue.record("mapping failed"); return }
    #expect(mcpClicks == true)

    guard case .success(.export(_, _, _, _, _, _, _, _, let cliClicks, _, _)) = CommandLineParser.parse(
        ["export", "/tmp/x.snitt", "--format", "mp4", "--out", "/tmp/d.mp4"])
    else { Issue.record("the CLI could not express an export"); return }
    #expect(cliClicks == true, "§4.8: the two frontends must not diverge on a default")
}

@Test("clicks: false is still honoured, so the default is a default and not a hardcode")
func clicksCanStillBeTurnedOff() {
    // The control. Without it, `clicksDefaultToOn` passes just as well against
    // an implementation that ignores the parameter entirely and always draws.
    guard case .success(.export(_, _, _, _, _, _, _, _, let clicks, _, _)) = MCPBridge.request(
        forTool: "snitt_export",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "format": "mp4","#
            + #""outputPath": "/tmp/d.mp4", "clicks": false}"#))
    else { Issue.record("mapping failed"); return }
    #expect(clicks == false)

    guard case .success(.export(_, _, _, _, _, _, _, _, let cliClicks, _, _)) = CommandLineParser.parse(
        ["export", "/tmp/x.snitt", "--format", "mp4", "--out", "/tmp/d.mp4", "--no-clicks"])
    else { Issue.record("the CLI could not express --no-clicks"); return }
    #expect(cliClicks == false)
}

@Test("Tidying a recording is one call: the ends come off unless the caller keeps them")
func trimBookendsDefaultsToOn() {
    // PR I. Discriminates against leaving `DeepTrimCriteria`'s own default
    // alone, which is `false` (correctly, for the editor), and would leave the
    // agent loop still needing snitt_trim plus this, with two unrelated
    // parameter vocabularies, on every recording.
    guard case .success(.autoDeepTrim(_, let mcp)) = MCPBridge.request(
        forTool: "snitt_auto_deep_trim",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt"}"#)) else {
        Issue.record("mapping failed"); return
    }
    #expect(mcp.trimBookends == true)

    guard case .success(.autoDeepTrim(_, let cli)) = CommandLineParser.parse(
        ["auto-deep-trim", "/tmp/x.snitt"]) else {
        Issue.record("the CLI could not express an auto-deep-trim"); return
    }
    #expect(cli.trimBookends == true, "§4.8: the two frontends must not diverge on a default")
}

@Test("Keeping the bookends is still possible, on both frontends")
func trimBookendsCanBeTurnedOff() {
    // The control for the test above, and the case the editor's own behaviour
    // depends on staying reachable.
    guard case .success(.autoDeepTrim(_, let mcp)) = MCPBridge.request(
        forTool: "snitt_auto_deep_trim",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "trimBookends": false}"#))
    else { Issue.record("mapping failed"); return }
    #expect(mcp.trimBookends == false)

    guard case .success(.autoDeepTrim(_, let cli)) = CommandLineParser.parse(
        ["auto-deep-trim", "/tmp/x.snitt", "--keep-bookends"]) else {
        Issue.record("the CLI could not express --keep-bookends"); return
    }
    #expect(cli.trimBookends == false)
}

@Test("A preset does not quietly put the bookends back")
func presetDoesNotResetTrimBookends() {
    // `--preset` REPLACES the whole criteria value, so setting trimBookends
    // before the flag loop rather than after it would leave
    // `auto-deep-trim x.snitt --preset aggressive` silently not trimming the
    // ends while the bare command does, a difference nothing else here would
    // catch.
    guard case .success(.autoDeepTrim(_, let cli)) = CommandLineParser.parse(
        ["auto-deep-trim", "/tmp/x.snitt", "--preset", "aggressive"]) else {
        Issue.record("the CLI could not express a preset"); return
    }
    #expect(cli.trimBookends == true)
}

@Test("The three bare parameters on snitt_start_recording now say what they do")
func bareParametersAreDocumented() {
    // `maxDurationSeconds`, `microphone` and `systemAudio` carried no
    // description at all while every other parameter on the surface was richly
    // documented, so an agent reading the schema learned their names and
    // nothing else. Least useful for maxDurationSeconds, whose whole job is to
    // stop a recording an agent may no longer be alive to stop.
    guard let tool = MCPBridge.toolDefinitions().first(where: { $0.name == "snitt_start_recording" }),
          let properties = tool.inputSchema["properties"] as? [String: Any] else {
        Issue.record("snitt_start_recording is missing"); return
    }
    for name in ["maxDurationSeconds", "microphone", "systemAudio"] {
        let text = (properties[name] as? [String: Any])?["description"] as? String
        #expect((text?.count ?? 0) > 40, "\(name) still has no real description: \(text ?? "none")")
    }
}

// MARK: - D107: captions, marker banners, and narration

@Test("Absent captions means the DOCUMENT decides, not off")
func captionsAbsentIsNilNotFalse() {
    // DISCRIMINATES AGAINST: `booleanValue(...) ?? false`, which is what every
    // other flag on this tool does and is wrong for exactly these two. A
    // `false` here would make an agent's export silently drop captions a
    // person had already turned on in the editor, §8's confidently-wrong
    // outcome, and the one the whole Optional exists to avoid. With `?? false`
    // this reads `captions == false` and fails.
    guard case .success(.export(_, _, _, _, _, _, _, _, _, let captions, let banners)) =
        MCPBridge.request(
            forTool: "snitt_export",
            arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "format": "mp4","#
                + #""outputPath": "/tmp/d.mp4"}"#)) else {
        Issue.record("mapping failed"); return
    }
    #expect(captions == nil)
    #expect(banners == nil)
}

@Test("captions and markerBanners carry both values through")
func captionsCarryThrough() {
    // The control: a bridge that hardcoded nil would pass the test above.
    guard case .success(.export(_, _, _, _, _, _, _, _, _, let captions, let banners)) =
        MCPBridge.request(
            forTool: "snitt_export",
            arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "format": "mp4","#
                + #""outputPath": "/tmp/d.mp4", "captions": true, "markerBanners": false}"#))
    else { Issue.record("mapping failed"); return }
    #expect(captions == true)
    #expect(banners == false)
}

@Test("snitt_narrate refuses to invent a time")
func narrateRequiresATime() {
    // DISCRIMINATES AGAINST: `numericValue(...) ?? 0`. Zero is a perfectly
    // valid anchor, so a default silently stacks every line an agent forgot to
    // place on the recording's first frame, and the call reports success. The
    // refusal has to name the parameter so the agent can fix it.
    guard case .failure(let error) = MCPBridge.request(
        forTool: "snitt_narrate",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "text": "hello"}"#))
    else { Issue.record("a narration with no time was accepted"); return }
    #expect(error.message.contains("atSeconds"))
}

@Test("snitt_narrate refuses blank text instead of writing nothing")
func narrateRefusesBlankText() {
    // DISCRIMINATES AGAINST: passing the text straight through.
    // `AuthoredNarration.words` returns [] for whitespace, so the write would
    // succeed, add no line, and report a cheerful success, the silent no-op
    // an agent hits by interpolating an empty variable.
    guard case .failure = MCPBridge.request(
        forTool: "snitt_narrate",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "text": "   ","#
            + #""atSeconds": 4}"#))
    else { Issue.record("blank narration was accepted"); return }
}

@Test("snitt_narrate refuses a negative time")
func narrateRefusesNegativeTime() {
    // Seconds are measured from the start of the recording, so there is no
    // time before it. Accepting one would place a line the transcript sorts
    // first and nothing ever reaches.
    guard case .failure = MCPBridge.request(
        forTool: "snitt_narrate",
        arguments: jsonArguments(#"{"bundlePath": "/tmp/x.snitt", "text": "hi","#
            + #""atSeconds": -1}"#))
    else { Issue.record("a negative narration time was accepted"); return }
}

@Test("snitt_narrate and snitt_transcript resolve a relative bundle path")
func transcriptToolsResolvePaths() {
    // DISCRIMINATES AGAINST: passing `bundlePath` through unresolved, which
    // `snitt_inspect` still does and which works only because the app happens
    // to be handed absolute paths today. A relative path would otherwise
    // resolve against `Snitt.app`'s own cwd, `/`, and the recording would
    // not be found (M3c finding #3, `PathResolver`).
    guard case .success(.transcript(let readPath)) = MCPBridge.request(
        forTool: "snitt_transcript",
        arguments: jsonArguments(#"{"bundlePath": "demo.snitt"}"#),
        workingDirectory: "/Users/x/project") else {
        Issue.record("mapping failed"); return
    }
    #expect(readPath == "/Users/x/project/demo.snitt")

    guard case .success(.addNarration(let writePath, let text, let at)) = MCPBridge.request(
        forTool: "snitt_narrate",
        arguments: jsonArguments(#"{"bundlePath": "demo.snitt", "text": "two words","#
            + #""atSeconds": 4.5}"#),
        workingDirectory: "/Users/x/project") else {
        Issue.record("mapping failed"); return
    }
    #expect(writePath == "/Users/x/project/demo.snitt")
    #expect(text == "two words")
    #expect(at == 4.5)
}

// MARK: - D108: finding a recording you lost track of

@Test("snitt_list_recordings needs nothing, and defaults to all of them")
func listRecordingsTakesNoArguments() {
    // A tool that required a limit would make an agent guess how many
    // recordings exist in order to ask how many exist.
    guard case .success(.listRecordings(let limit)) = MCPBridge.request(
        forTool: "snitt_list_recordings", arguments: [:]) else {
        Issue.record("mapping failed"); return
    }
    #expect(limit == nil)
}

@Test("A limit that is not a whole positive number is refused, not rounded")
func listRecordingsLimitIsValidated() {
    // DISCRIMINATES AGAINST: `Int(value)`, which truncates. `limit: 0.5`
    // would silently become 0 and return an empty list that reads exactly
    // like an empty directory, and `limit: -1` would do the same. Both are
    // answers about somebody's disk that are simply not true.
    for bad in ["0", "-1", "0.5"] {
        guard case .failure = MCPBridge.request(
            forTool: "snitt_list_recordings",
            arguments: jsonArguments("{\"limit\": \(bad)}")) else {
            Issue.record("limit \(bad) was accepted"); return
        }
    }
    guard case .success(.listRecordings(let limit)) = MCPBridge.request(
        forTool: "snitt_list_recordings",
        arguments: jsonArguments(#"{"limit": 5}"#)) else {
        Issue.record("mapping failed"); return
    }
    #expect(limit == 5)
}
