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
        case "snitt_stop_recording", "snitt_add_marker":
            json = #"{"sessionId": "abc"}"#
        case "snitt_inspect":
            json = #"{"bundlePath": "/tmp/x.snitt"}"#
        case "snitt_trim":
            json = #"{"bundlePath": "/tmp/x.snitt", "autoTrim": true}"#
        case "snitt_export":
            json = #"{"bundlePath": "/tmp/x.snitt", "format": "mp4", "outputPath": "/tmp/demo.mp4"}"#
        case "snitt_diagnostics_export":
            json = #"{"outputPath": "/tmp/diagnostics.json"}"#
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
                      "snitt_stop_recording", "snitt_status", "snitt_add_marker",
                      "snitt_inspect", "snitt_trim", "snitt_export",
                      "snitt_diagnostics_export"])
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

// All three tests below `chdir` the real process to prove a relative path
// resolves against the CALLER's cwd rather than arriving verbatim (a fixed
// absolute path, as every other fixture in this file uses, cannot tell a
// resolving implementation from a pass-through one). `chdir` is process-wide,
// mutable state — swift-testing parallelizes free functions across the whole
// target by default, so left ungrouped these three would race each other's
// `chdir` calls. Grouped in a serialized suite so they cannot run
// concurrently, the same fix `HotkeyRegistrationTests` uses for a different
// shared, real, OS-level resource.
@Suite(.serialized)
struct RelativePathResolutionTests {
    @Test("snitt_diagnostics_export resolves a relative outputPath against this process's cwd")
    func diagnosticsExportResolvesRelativePaths() throws {
        // `.diagnostics`'s own doc comment (`Protocol.swift`) declares
        // `outputPath` arrives already resolved against the CALLER's working
        // directory. `snitt-cli` honours that via `PathResolver.resolve`
        // before it ever builds the request; `MCPBridge.request` — the only
        // place `snitt-mcp` builds one — forwarded the raw string instead, so
        // a relative path from an MCP client would resolve wherever
        // `AutomationHost`/`Snitt.app` happened to have its cwd, not the
        // caller's, exactly the M3c finding #3 shape this file's
        // `PathResolver` doc comment describes for `bundlePath`/`outputPath`
        // generally.
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPBridgeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let previousCWD = FileManager.default.currentDirectoryPath
        #expect(FileManager.default.changeCurrentDirectoryPath(scratchDir.path))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previousCWD) }
        // `/tmp` is itself a symlink to `/private/tmp` on macOS, and `chdir`
        // resolves it — read the resolved cwd back rather than trust
        // `scratchDir.path`, so the expectation isn't comparing a symlinked
        // path against its resolved target.
        let resolvedCWD = FileManager.default.currentDirectoryPath

        guard case .success(let body) = MCPBridge.request(
            forTool: "snitt_diagnostics_export",
            arguments: jsonArguments(#"{"outputPath": "diagnostics.json"}"#))
        else { Issue.record("MCP could not express a diagnostics export"); return }
        guard case .diagnostics(let resolvedPath) = body else {
            Issue.record("expected .diagnostics, got \(body)"); return
        }

        #expect(resolvedPath == resolvedCWD + "/diagnostics.json",
                "a relative outputPath must resolve against the caller's working directory, not arrive verbatim")
    }

    @Test("snitt_trim resolves a relative bundlePath against this process's cwd")
    func trimResolvesRelativePaths() throws {
        // Same shape as `diagnosticsExportResolvesRelativePaths` above: only
        // a relative path discriminates a resolving implementation from a
        // pass-through one.
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPBridgeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let previousCWD = FileManager.default.currentDirectoryPath
        #expect(FileManager.default.changeCurrentDirectoryPath(scratchDir.path))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previousCWD) }
        let resolvedCWD = FileManager.default.currentDirectoryPath

        guard case .success(let body) = MCPBridge.request(
            forTool: "snitt_trim",
            arguments: jsonArguments(#"{"bundlePath": "d.snitt", "autoTrim": true}"#))
        else { Issue.record("MCP could not express a trim"); return }
        guard case .trim(let resolvedPath, _, _, _) = body else {
            Issue.record("expected .trim, got \(body)"); return
        }

        #expect(resolvedPath == resolvedCWD + "/d.snitt",
                "a relative bundlePath must resolve against the caller's working directory, not arrive verbatim")
    }

    @Test("snitt_export resolves relative bundlePath and outputPath against this process's cwd")
    func exportResolvesRelativePaths() throws {
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPBridgeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let previousCWD = FileManager.default.currentDirectoryPath
        #expect(FileManager.default.changeCurrentDirectoryPath(scratchDir.path))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previousCWD) }
        let resolvedCWD = FileManager.default.currentDirectoryPath

        guard case .success(let body) = MCPBridge.request(
            forTool: "snitt_export",
            arguments: jsonArguments(#"{"bundlePath": "d.snitt", "format": "mp4", "outputPath": "out.mp4"}"#))
        else { Issue.record("MCP could not express an export"); return }
        guard case .export(let resolvedBundlePath, _, let resolvedOutputPath, _, _, _) = body else {
            Issue.record("expected .export, got \(body)"); return
        }

        #expect(resolvedBundlePath == resolvedCWD + "/d.snitt",
                "a relative bundlePath must resolve against the caller's working directory, not arrive verbatim")
        #expect(resolvedOutputPath == resolvedCWD + "/out.mp4",
                "a relative outputPath must resolve against the caller's working directory, not arrive verbatim")
    }
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
    guard case .success(.export(_, _, _, let scale, _, _)) = mapped else {
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
        forTool: "snitt_add_marker",
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
    guard case .success(.export(_, _, _, _, let chapters, _)) = mapped else {
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
          case .export(_, let format, _, _, _, let maxSize) = request else {
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
          case .export(_, _, _, _, _, let maxSize) = request else {
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
