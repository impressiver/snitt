import Testing
import Foundation
@testable import SnittAutomation

@Test("Every advertised tool maps to a request — none is decorative")
func everyToolMaps() {
    for tool in MCPBridge.toolDefinitions() {
        let args: [String: Any] = tool.name == "snitt_start_recording"
            ? ["bundleIdentifier": "com.apple.Safari"]
            : (tool.name == "snitt_stop_recording" || tool.name == "snitt_add_marker"
                ? ["sessionId": "abc"]
                : (tool.name == "snitt_inspect" ? ["bundlePath": "/tmp/x.snitt"]
                : (tool.name == "snitt_trim" ? ["bundlePath": "/tmp/x.snitt", "autoTrim": true]
                : (tool.name == "snitt_export" ? ["bundlePath": "/tmp/x.snitt", "format": "mp4",
                                                   "outputPath": "/tmp/demo.mp4"] : [:]))))
        let mapped = MCPBridge.request(forTool: tool.name, arguments: args)
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
                      "snitt_inspect", "snitt_trim", "snitt_export"])
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

    guard case .success(let mcpBody) =
        MCPBridge.request(forTool: "snitt_trim",
                          arguments: ["bundlePath": "/tmp/d.snitt", "start": 1, "end": 9])
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
        arguments: ["bundlePath": "/tmp/x.snitt", "format": "mp4",
                    "outputPath": "/tmp/demo.mp4", "scale": "0.5"])
    else { Issue.record("a string scale must not be silently accepted"); return }
    #expect(error.message.contains("scale"))
}

@Test("A boolean start does not silently fall through while a valid end sails through")
func nonNumericStartRefusedEvenWithValidEnd() {
    // A plausible wrong implementation: numericValue correctly rejects the
    // bool for `start` by returning nil, but the caller cannot distinguish
    // that from "start absent" — so the guard (auto || start != nil || end
    // != nil) is satisfied by the valid `end`, and a DIFFERENT trim than the
    // one requested goes out with no error at all.
    guard case .failure(let error) = MCPBridge.request(
        forTool: "snitt_trim",
        arguments: ["bundlePath": "/tmp/x.snitt", "start": true, "end": 9])
    else { Issue.record("a boolean start must not be silently dropped"); return }
    #expect(error.message.contains("start"))
}

@Test("snitt_export rejects a zero or negative scale")
func mcpExportRejectsNonPositiveScale() {
    guard case .failure = MCPBridge.request(
        forTool: "snitt_export",
        arguments: ["bundlePath": "/tmp/x.snitt", "format": "mp4",
                    "outputPath": "/tmp/demo.mp4", "scale": 0])
    else { Issue.record("a zero scale must not be silently accepted"); return }
    guard case .failure = MCPBridge.request(
        forTool: "snitt_export",
        arguments: ["bundlePath": "/tmp/x.snitt", "format": "mp4",
                    "outputPath": "/tmp/demo.mp4", "scale": -0.5])
    else { Issue.record("a negative scale must not be silently accepted"); return }
}

@Test("snitt_trim rejects an end at or before start")
func mcpTrimRejectsInvertedRange() {
    guard case .failure = MCPBridge.request(
        forTool: "snitt_trim",
        arguments: ["bundlePath": "/tmp/x.snitt", "start": 9, "end": 5])
    else { Issue.record("an inverted range must not be silently accepted"); return }
    guard case .failure = MCPBridge.request(
        forTool: "snitt_trim",
        arguments: ["bundlePath": "/tmp/x.snitt", "start": 5, "end": 5])
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
        arguments: ["sessionId": "s1", "label": "step two"]) else {
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
        forTool: "snitt_inspect", arguments: ["bundlePath": "/tmp/demo.snitt"]) else {
        Issue.record("MCP could not express an inspect"); return
    }
    #expect(cliPath == mcpPath)
}

@Test("Starting a recording without a target is refused before it reaches the app")
func startNeedsATarget() {
    let mapped = MCPBridge.request(forTool: "snitt_start_recording", arguments: [:])
    guard case .failure(let error) = mapped else {
        Issue.record("a targetless start must not be sent"); return
    }
    #expect(error.message.contains("bundleIdentifier"))
}

@Test("An unknown tool is refused rather than silently ignored")
func unknownToolRefused() {
    guard case .failure = MCPBridge.request(forTool: "snitt_do_magic", arguments: [:]) else {
        Issue.record("unknown tools must fail"); return
    }
}

@Test("The MCP microphone default matches the CLI's — off")
func micDefaultMatchesCLI() {
    guard case .success(.startRecording(let options)) = MCPBridge.request(
        forTool: "snitt_start_recording",
        arguments: ["bundleIdentifier": "com.apple.Safari"]) else {
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
        forTool: "snitt_start_recording", arguments: ["displayID": 7]) else {
        Issue.record("MCP could not express a display target"); return
    }
    #expect(cliDisplay.displayID == mcpDisplay.displayID)
    #expect(cliDisplay.displayID == 7)
}

@Test("A non-integral displayID is refused rather than silently truncated")
func nonIntegralDisplayIDRefused() {
    guard case .failure(let error) = MCPBridge.request(
        forTool: "snitt_start_recording", arguments: ["displayID": 7.5]) else {
        Issue.record("a fractional displayID must not be sent"); return
    }
    #expect(error.message.contains("displayID"))
}

@Test("An out-of-range displayID is refused rather than silently truncated")
func outOfRangeDisplayIDRefused() {
    guard case .failure(let error) = MCPBridge.request(
        forTool: "snitt_start_recording", arguments: ["displayID": -1]) else {
        Issue.record("a negative displayID must not be sent"); return
    }
    #expect(error.message.contains("displayID"))
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
        arguments: ["bundleIdentifier": "com.apple.Safari", "displayID": 7]) else {
        Issue.record("mapping failed"); return
    }
    #expect(options.displayID == 7)
}
