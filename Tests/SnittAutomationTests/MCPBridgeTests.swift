import Testing
import Foundation
@testable import SnittAutomation

@Test("Every advertised tool maps to a request — none is decorative")
func everyToolMaps() {
    for tool in MCPBridge.toolDefinitions() {
        let args: [String: Any] = tool.name == "snitt_start_recording"
            ? ["bundleIdentifier": "com.apple.Safari"]
            : (tool.name == "snitt_stop_recording" ? ["sessionId": "abc"] : [:])
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
                      "snitt_stop_recording", "snitt_status"])
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
