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

/// What the two trim tools tell an agent about ITS OWN recordings.
///
/// The engine has counted reported input toward auto-trim since D72 —
/// `autoTrimRange` says so in as many words. The tool description did not, and
/// went on telling agents "agent recordings have no input events and are
/// refused" long after that stopped being true. An agent believes the
/// description; it never reads `autoTrimRange`.
@Suite
struct AgentTrimGuidanceTests {

    private func tool(_ name: String) throws -> ToolDefinition {
        try #require(MCPBridge.toolDefinitions().first { $0.name == name })
    }

    private func autoTrimText(_ tool: ToolDefinition) throws -> String {
        let properties = try #require(tool.inputSchema["properties"] as? [String: Any])
        let autoTrim = try #require(properties["autoTrim"] as? [String: Any])
        return try #require(autoTrim["description"] as? String)
    }

    @Test("snitt_trim no longer tells agents auto-trim cannot work for them")
    func autoTrimIsNotDescribedAsHumanOnly() throws {
        let trim = try tool("snitt_trim")
        let text = trim.description + " " + (try autoTrimText(trim))
        // The exact claim that was false: it is refused for want of EVENTS, not
        // for being an agent's recording.
        #expect(!text.lowercased().contains("only works on human"),
                "still claims auto-trim is human-only: \(text)")
        #expect(text.contains("snitt_report_input") || text.lowercased().contains("reported"),
                "does not tell an agent how to make auto-trim work: \(text)")
    }

    @Test("The two trim tools describe different jobs")
    func theTwoTrimsAreDistinguishable() throws {
        let bookends = try tool("snitt_trim").description.lowercased()
        let deep = try tool("snitt_auto_deep_trim").description.lowercased()
        // An agent choosing between them needs to know one takes the ENDS off
        // and the other removes gaps throughout. Two descriptions that both
        // said "cut dead time" would leave it guessing.
        #expect(bookends.contains("setup") || bookends.contains("bookend"),
                "snitt_trim does not say it trims the ends: \(bookends)")
        #expect(deep.contains("spans where nothing happened") || deep.contains("gap"),
                "snitt_auto_deep_trim does not say it removes interior gaps: \(deep)")
    }

    @Test("Reported input really does satisfy auto-trim, not just in the prose")
    func reportedInputActuallyUnlocksAutoTrim() throws {
        // The claim the description now makes, checked against the engine
        // rather than trusted: a recording whose ONLY input is reported still
        // auto-trims.
        let reported = [
            LoggedEvent(timeSeconds: 4.0, kind: .click, x: 0.5, y: 0.5, source: .reported),
            LoggedEvent(timeSeconds: 16.0, kind: .cursor, x: 0.6, y: 0.4, source: .reported),
        ]
        let range = try EditDecisionList.autoTrimRange(events: reported, duration: 20)
        #expect(abs(range.start - 3.5) < 0.001)
        #expect(abs(range.end - 16.5) < 0.001)

        // And markers alone still are not enough — a marker says "this moment
        // matters", not "something happened here".
        let markersOnly = [LoggedEvent(timeSeconds: 5, kind: .marker, label: "here")]
        #expect(throws: AutoTrimError.noInputEvents) {
            try EditDecisionList.autoTrimRange(events: markersOnly, duration: 20)
        }
    }
}
