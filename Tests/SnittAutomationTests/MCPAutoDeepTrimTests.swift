import Foundation
import Testing
@testable import SnittAutomation
@testable import SnittDocument

/// `snitt_auto_deep_trim` (D57), the agent-facing half.
@Suite
struct MCPAutoDeepTrimTests {

    private func criteria(_ json: String) -> DeepTrimCriteria? {
        guard case .success(.autoDeepTrim(_, let criteria)) = MCPBridge.request(
            forTool: "snitt_auto_deep_trim", arguments: jsonArguments(json)) else { return nil }
        return criteria
    }

    @Test("The tool and the CLI send the identical request")
    func mcpAndCliCannotDiverge() throws {
        // §4.8: the CLI and the MCP server must be incapable of diverging. Two
        // parsers for one feature is exactly how they would, and this is the
        // assertion that stops it — not that each "succeeds", but that the
        // BODIES match.
        let mcp = try #require(criteria(
            #"{"bundlePath": "/tmp/a.snitt", "preset": "aggressive", "inputPadding": 2}"#))
        guard case .success(.autoDeepTrim(_, let cli)) = CommandLineParser.parse(
            ["auto-deep-trim", "/tmp/a.snitt", "--preset", "aggressive", "--input-padding", "2"])
        else { Issue.record("the CLI could not express it"); return }
        #expect(mcp == cli, "MCP \(mcp) vs CLI \(cli)")
    }

    @Test("The bundle path is carried, not merely accepted")
    func pathIsCarried() {
        guard case .success(.autoDeepTrim(let path, _)) = MCPBridge.request(
            forTool: "snitt_auto_deep_trim",
            arguments: jsonArguments(#"{"bundlePath": "/tmp/demo.snitt"}"#))
        else { Issue.record("did not map"); return }
        // A bridge that mapped every call to an empty path would pass a
        // success-only assertion.
        #expect(path == "/tmp/demo.snitt")
    }

    @Test("With no options it uses the default preset")
    func defaultsToTheDefaultPreset() throws {
        #expect(try #require(criteria(#"{"bundlePath": "/tmp/a.snitt"}"#))
                == DeepTrimCriteria.preset(.default))
    }

    @Test("Every setting overrides one part of the preset, keeping the rest")
    func settingsComposeWithThePreset() throws {
        let base = DeepTrimCriteria.preset(.conservative)
        let cases: [(String, String, (DeepTrimCriteria) -> DeepTrimCriteria)] = [
            ("minSpan", "9", { var c = $0; c.minimumSpan = 9; return c }),
            ("audioSilence", "0.5", { var c = $0; c.audioSilenceFraction = 0.5; return c }),
            ("frameStillness", "0.09", { var c = $0; c.frameStillnessThreshold = 0.09; return c }),
            ("inputPadding", "2", { var c = $0; c.inputPadding = 2; return c }),
            ("readingTime", "3", { var c = $0; c.subtitleReadingTime = 3; return c }),
        ]
        // Each key has its own entry in the bridge, so exercising one proves
        // nothing about the other four — the lesson the CLI's own parser test
        // learned when a mutant survived it.
        for (key, value, expected) in cases {
            let parsed = try #require(criteria(
                #"{"bundlePath": "/tmp/a.snitt", "preset": "conservative", "\#(key)": \#(value)}"#),
                "\(key) did not map")
            #expect(parsed == expected(base), "\(key) produced \(parsed)")
        }
    }

    @Test("An unknown preset is refused, and the message names the real ones")
    func unknownPresetIsRefused() {
        guard case .failure(let error) = MCPBridge.request(
            forTool: "snitt_auto_deep_trim",
            arguments: jsonArguments(#"{"bundlePath": "/tmp/a.snitt", "preset": "brutal"}"#))
        else { Issue.record("accepted an unknown preset"); return }
        for preset in DeepTrimPreset.allCases {
            #expect(error.message.contains(preset.rawValue), "missing \(preset.rawValue)")
        }
    }

    @Test("A negative setting is refused rather than silently disabling a criterion")
    func negativeSettingsAreRefused() {
        guard case .failure = MCPBridge.request(
            forTool: "snitt_auto_deep_trim",
            arguments: jsonArguments(#"{"bundlePath": "/tmp/a.snitt", "minSpan": -5}"#))
        else { Issue.record("accepted a negative minSpan"); return }
    }

    @Test("Without a bundle path it is refused")
    func bundlePathIsRequired() {
        guard case .failure = MCPBridge.request(
            forTool: "snitt_auto_deep_trim", arguments: jsonArguments(#"{"preset": "default"}"#))
        else { Issue.record("accepted a call with no bundlePath"); return }
    }

    // MARK: - What the agent is told

    @Test("The description says this one works on the agent's own recordings")
    func descriptionNamesTheDistinguishingFact() throws {
        let tool = try #require(MCPBridge.toolDefinitions()
            .first { $0.name == "snitt_auto_deep_trim" })
        // The fact an agent most needs and cannot infer: snitt_trim's autoTrim
        // is REFUSED on agent recordings for want of input events, and this is
        // not. Without it, an agent that has been refused once reasonably
        // concludes automatic trimming is unavailable to it.
        #expect(tool.description.contains("snitt_trim"),
                "does not distinguish itself from snitt_trim")
        #expect(tool.description.lowercased().contains("non-destructive")
                || tool.description.lowercased().contains("never touches"),
                "does not say it is safe to run: \(tool.description)")
    }

    @Test("The preset enum in the schema is the real list of presets")
    func schemaEnumeratesRealPresets() throws {
        let tool = try #require(MCPBridge.toolDefinitions()
            .first { $0.name == "snitt_auto_deep_trim" })
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        let preset = try #require(properties["preset"] as? [String: Any])
        let values = try #require(preset["enum"] as? [String])
        // Hand-written enum values are how a schema comes to offer a preset
        // that no longer exists.
        #expect(Set(values) == Set(DeepTrimPreset.allCases.map(\.rawValue)))
    }
}
