import Foundation
import SnittDocument
import CoreFoundation

public struct ToolDefinition: Encodable, Sendable {
    public let name: String
    public let description: String
    /// Backing storage for the JSON Schema. `[String: Any]` cannot itself be
    /// `Sendable`, so the schema is held as this `Sendable`, `Codable` value and
    /// only ever surfaced as `[String: Any]` through the computed property below.
    private let schema: JSONAnyValue

    /// JSON Schema for the tool's arguments, reconstituted on access so it can
    /// be embedded verbatim in the MCP response.
    public var inputSchema: [String: Any] {
        schema.asFoundationValue as? [String: Any] ?? [:]
    }

    public init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        let data = (try? JSONSerialization.data(withJSONObject: inputSchema)) ?? Data()
        self.schema = (try? JSONDecoder().decode(JSONAnyValue.self, from: data)) ?? .object([:])
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, inputSchema
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(schema, forKey: .inputSchema)
    }
}

/// A JSON value that can hold arbitrary JSON Schema shapes for `Encodable`
/// conformance and `Sendable` storage, since `[String: Any]` itself is neither.
private enum JSONAnyValue: Codable, Sendable {
    case object([String: JSONAnyValue])
    case array([JSONAnyValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode([String: JSONAnyValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONAnyValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Recovers the plain `Any`-based Foundation representation (`[String: Any]`,
    /// `[Any]`, `String`, `Double`, `Bool`, or `NSNull`) for callers that need to
    /// hand a JSON Schema to `JSONSerialization`-based APIs.
    var asFoundationValue: Any {
        switch self {
        case .object(let value): return value.mapValues { $0.asFoundationValue }
        case .array(let value): return value.map { $0.asFoundationValue }
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        }
    }
}

/// Why an MCP tool call could not be mapped to a request.
///
/// A purpose-built type rather than `String`: `Result` constrains `Failure` to
/// `Error`, and a retroactive `String: Error` conformance in a library target
/// leaks to every importer. `CommandLineParser.ParseFailure` follows the same
/// pattern for the CLI side.
public struct MCPBridgeError: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Maps MCP tool calls onto the same request bodies the CLI builds.
///
/// The bridge adds no capability of its own. §4.8 requires the two frontends to
/// be incapable of diverging, so both construct `AutomationRequest.Body` values
/// and both travel through `AutomationClient`.
public enum MCPBridge {
    /// Server-level guidance, returned in the `initialize` result.
    ///
    /// A tool description is read at *call* time and answers "how do I invoke
    /// this". Nothing in the tool list answers "why would I record a screen",
    /// which is read at *decide* time — an agent that never considers making a
    /// demo never reads the schemas. That gap is what this field is for
    /// (S5, D63); hosts may place it in the system prompt.
    ///
    /// Says what the tool list structurally cannot: that these tools wrap a
    /// recording around work done with OTHER tools (D49), that the result is
    /// unwatchable so `snitt_inspect` is the only way to know what was made,
    /// and that Snitt.app must already be running because these tools ask it to
    /// record rather than recording themselves (§4.9).
    public static let serverInstructions = """
        Snitt records a macOS window to a .snitt bundle, so you can show work \
        instead of describing it: a demo attached to a pull request, a bug \
        reproduced on video, a before-and-after.

        Snitt films; it does not click or type. Drive the UI with your own \
        tools and use these to wrap a recording around that work.

        The loop is snitt_start_recording, then the work — calling \
        snitt_add_marker at each step a reviewer should be able to jump to — \
        then snitt_stop_recording, snitt_inspect, snitt_export. You cannot \
        watch what you recorded, so snitt_inspect is how you find out what you \
        made, and its output is what to quote when describing the demo. Pass \
        maxSize to snitt_export when the file is going somewhere with an \
        attachment limit.

        Snitt.app must already be running: these tools ask it to record, they \
        do not record themselves, and if it is not running there is nobody to \
        start it. Recording is scoped to one application's window by default \
        — prefer bundleIdentifier over displayID, which additionally requires \
        a person to have turned on full-display agent recording. A person at \
        the machine can see and stop any recording at any time.
        """

    public static func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "snitt_list_targets",
                description: "List windows and displays that can be recorded.",
                inputSchema: ["type": "object", "properties": [String: Any]()]),
            ToolDefinition(
                name: "snitt_start_recording",
                description: "Start recording a window belonging to an application. "
                           + "Returns a session id used to stop it. "
                           + "EVERYTHING IN THE WINDOW IS RECORDED, including its "
                           + "chrome — a browser's tab strip puts the titles of every "
                           + "other open tab into every frame, and those routinely name "
                           + "accounts, orders and internal tools. Before recording a "
                           + "browser, move the page you are demonstrating into its own "
                           + "window, or expect to crop the strip out before sharing.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bundleIdentifier": [
                            "type": "string",
                            "description": "Bundle id of the app whose window to record. "
                                + "Preferred over displayID — window recording needs no "
                                + "extra opt-in.",
                        ],
                        "windowID": [
                            "type": "number",
                            "description": "Which window, from snitt_list_targets. "
                                + "REQUIRED when the application has more than one "
                                + "window open — without it Snitt refuses rather than "
                                + "guessing, because guessing records whichever window "
                                + "is largest and you will not find out until you watch "
                                + "the result.",
                        ],
                        "displayID": [
                            "type": "number",
                            "description": "Numeric id of a whole display to record instead "
                                + "of a window. Requires a person to have separately "
                                + "enabled full-display agent recording in Snitt's "
                                + "settings; refused otherwise. Prefer bundleIdentifier.",
                        ],
                        "microphone": ["type": "boolean", "default": false],
                        "systemAudio": ["type": "boolean", "default": true],
                        "maxDurationSeconds": ["type": "number"],
                    ],
                    // Exactly one of bundleIdentifier/displayID is required, which
                    // JSON Schema's flat "required" array cannot express (that would
                    // need "anyOf" over two required-arrays). Validated instead in
                    // `request(forTool:arguments:)`, where the actionable message can
                    // name both options together.
                ]),
            ToolDefinition(
                name: "snitt_stop_recording",
                description: "Stop a recording and return the path to its .snitt bundle.",
                inputSchema: [
                    "type": "object",
                    "properties": ["sessionId": ["type": "string"]],
                    "required": ["sessionId"],
                ]),
            ToolDefinition(
                name: "snitt_pause_recording",
                description: "Stop filming without ending the recording. Use it "
                           + "while you think, read, or do work that is not worth "
                           + "showing — the finished video jumps straight from "
                           + "pause to resume with no dead air. Drops a marker so "
                           + "the gap is visible in the timeline.",
                inputSchema: [
                    "type": "object",
                    "properties": ["sessionId": ["type": "string"]],
                    "required": ["sessionId"],
                ]),
            ToolDefinition(
                name: "snitt_resume_recording",
                description: "Start filming again after snitt_pause_recording. "
                           + "Time spent paused still counts toward "
                           + "maxDurationSeconds, so a session left paused "
                           + "eventually stops on its own.",
                inputSchema: [
                    "type": "object",
                    "properties": ["sessionId": ["type": "string"]],
                    "required": ["sessionId"],
                ]),
            ToolDefinition(
                name: "snitt_report_input",
                description: "Tell Snitt where you clicked or moved the pointer. "
                           + "Browser automation dispatches events into the page, so "
                           + "the real cursor never moves and the recording shows "
                           + "buttons changing with nothing visibly causing it — "
                           + "unwatchable as a demo. Reporting each click puts it on "
                           + "the recording's clock so it can be drawn. Coordinates are "
                           + "FRACTIONS of the recorded window (0-1, origin top-left), "
                           + "not page or screen pixels: compute them from the element's "
                           + "position plus the browser's own chrome offset. Snitt does "
                           + "not click anything — it records what you say you did.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "sessionId": ["type": "string"],
                        "kind": ["type": "string",
                                 "enum": ["click", "cursor", "keystroke"],
                                 "description": "\"click\", \"cursor\" (a move with no "
                                     + "click), or \"keystroke\" (you typed something). "
                                     + "A keystroke needs no x/y and MUST NOT carry a "
                                     + "label: report WHEN you typed, never what. It is "
                                     + "what lets snitt_trim's autoTrim find the bookends "
                                     + "of a session you drove from a terminal."],
                        "x": ["type": "number", "description": "0-1 across the window"],
                        "y": ["type": "number", "description": "0-1 down the window"],
                    ],
                    // x/y are required for the pointer kinds and checked in the
                    // handler, not here: JSON Schema cannot express "required
                    // unless kind is keystroke" in a form every client honours.
                    "required": ["sessionId", "kind"],
                ]),
            ToolDefinition(
                name: "snitt_screenshot",
                description: "Save the frame the recording is currently on, and "
                           + "mark that instant. Use it to SEE the window you are "
                           + "recording — you cannot watch the video, and this is "
                           + "the only way to check the demo looks right while it "
                           + "is still fixable. The image and its marker come from "
                           + "the same frame, so 'what I saw' and 'what I said "
                           + "about it' share one timestamp. Works while paused.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "sessionId": ["type": "string"],
                        "label": ["type": "string",
                                  "description": "What this moment shows. Defaults to \"Screenshot\"."],
                    ],
                    "required": ["sessionId"],
                ]),
            ToolDefinition(
                name: "snitt_status",
                description: "Report whether a recording is currently running.",
                inputSchema: ["type": "object", "properties": [String: Any]()]),
            ToolDefinition(
                name: "snitt_add_marker",
                description: "Drop a labelled marker into the running recording, so a "
                           + "reviewer can jump to this moment. Narrate what you just did.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "sessionId": ["type": "string"],
                        "label": [
                            "type": "string",
                            "description": "What is happening at this moment",
                        ],
                    ],
                    "required": ["sessionId"],
                ]),
            ToolDefinition(
                name: "snitt_inspect",
                description: "Read a recording's metadata — duration, markers, capture "
                           + "health, git context — without watching it. Use this to "
                           + "describe a demo you made.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bundlePath": [
                            "type": "string",
                            "description": "Path printed by snitt_stop_recording",
                        ],
                    ],
                    "required": ["bundlePath"],
                ]),
            ToolDefinition(
                name: "snitt_trim",
                description: "Cut the setup and teardown off a recording — the "
                           + "seconds before the first thing happened and after the last "
                           + "— by editing its edit decision list. Never touches "
                           + "capture.mov. Give it an explicit start/end range, or "
                           + "autoTrim to find the bookends from input events. "
                           + "IF YOU REPORTED YOUR CLICKS with snitt_report_input, "
                           + "autoTrim works on your own recording: reported input is "
                           + "input. Without any input events it is refused, because "
                           + "there is nothing to trim against.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bundlePath": [
                            "type": "string",
                            "description": "Path printed by snitt_stop_recording",
                        ],
                        "start": ["type": "number", "description": "Seconds to cut from the start"],
                        "end": ["type": "number", "description": "Seconds to cut from the end"],
                        "autoTrim": [
                            "type": "boolean",
                            "description": "Trim bookends to the first and last input "
                                + "event. Counts input you REPORTED as well as input the "
                                + "OS saw, so this works on a recording you made if you "
                                + "called snitt_report_input as you went. Refused only "
                                + "when the recording has no input events at all — "
                                + "markers do not count, since a marker says \"this "
                                + "moment matters\", not \"something happened here\".",
                        ],
                    ],
                    "required": ["bundlePath"],
                ]),
            ToolDefinition(
                name: "snitt_crop",
                description: "Crop the recording to a region, non-destructively — "
                           + "capture.mov is never modified and the crop can be "
                           + "removed again. Use it to cut away a cluttered "
                           + "desktop, a second monitor, or window chrome so the "
                           + "demo shows only what matters. Returns the pixel "
                           + "dimensions the export will have.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bundlePath": [
                            "type": "string",
                            "description": "Path printed by snitt_stop_recording",
                        ],
                        "x": ["type": "number", "description": "Left edge, as a fraction of the frame (0-1)"],
                        "y": ["type": "number", "description": "Top edge, as a fraction of the frame (0-1)"],
                        "width": ["type": "number", "description": "Width, as a fraction of the frame (0-1)"],
                        "height": ["type": "number", "description": "Height, as a fraction of the frame (0-1)"],
                        "reset": [
                            "type": "boolean",
                            "description": "Remove an existing crop instead of setting one.",
                        ],
                    ],
                    "required": ["bundlePath"],
                ]),
            ToolDefinition(
                name: "snitt_auto_deep_trim",
                description: "Remove the spans where nothing happened — no sound, no "
                           + "movement on screen, no input, no marker, nothing being "
                           + "said. Non-destructive: it appends cuts to the edit "
                           + "decision list and never touches capture.mov, so the "
                           + "result is reversible and safe to run before deciding. "
                           + "Unlike snitt_trim's autoTrim, this WORKS ON RECORDINGS "
                           + "YOU MADE: it needs no input events, because it reads the "
                           + "picture and the audio instead. Running it twice is safe — "
                           + "the second run proposes nothing already cut. Use it before "
                           + "snitt_export to hand someone a demo without the minutes "
                           + "spent waiting for a page to load.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bundlePath": [
                            "type": "string",
                            "description": "Path printed by snitt_stop_recording",
                        ],
                        "preset": [
                            "type": "string",
                            "enum": DeepTrimPreset.allCases.map(\.rawValue),
                            "description": "How much footage survives. conservative keeps "
                                + "the most and only removes long, unambiguous gaps; "
                                + "aggressive keeps the least. Defaults to default. Any "
                                + "of the settings below override one part of it.",
                        ],
                        "minSpan": [
                            "type": "number",
                            "description": "Shortest gap worth removing, in seconds.",
                        ],
                        "audioSilence": [
                            "type": "number",
                            "description": "Audio at or below this fraction of the "
                                + "track's own typical level counts as silence.",
                        ],
                        "frameStillness": [
                            "type": "number",
                            "description": "Frame-to-frame change at or below this "
                                + "counts as a still picture (0-1).",
                        ],
                        "inputPadding": [
                            "type": "number",
                            "description": "Seconds kept either side of a click, "
                                + "keystroke or marker.",
                        ],
                        "readingTime": [
                            "type": "number",
                            "description": "Seconds a spoken word stays protected after "
                                + "it finishes, so captions are not cut mid-read.",
                        ],
                    ],
                    "required": ["bundlePath"],
                ]),
            ToolDefinition(
                name: "snitt_export",
                description: "Render the trimmed recording to a movie file and return a "
                           + "manifest — duration, dimensions, byte size, chapters — that "
                           + "an agent can quote without watching the file. gif output has "
                           + "no audio track: a silent demo is inherent to the format, not "
                           + "a bug, so say so rather than let a viewer discover it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bundlePath": [
                            "type": "string",
                            "description": "Path printed by snitt_stop_recording",
                        ],
                        "format": [
                            "type": "string",
                            "description": "\"mp4\" or \"gif\". gif carries no audio track.",
                        ],
                        "outputPath": ["type": "string", "description": "Where to write the movie"],
                        "scale": ["type": "number", "default": 1.0,
                                  "description": "Pixel-dimension multiplier"],
                        "chapters": ["type": "boolean", "default": false,
                                     "description": "Write a .vtt chapter list beside the output, from marker labels — navigation, not speech"],
                        "subtitles": ["type": "boolean", "default": false,
                                      "description": "Write a .subtitles.vtt beside the output from marker TRANSCRIPTS. Only markers that carry narration produce cues, so a demo with no transcripts produces an empty file."],
                        "maxSize": [
                            "type": "string",
                            "description": "A byte budget like \"10MB\". The exporter walks "
                                + "down scale/quality until the file fits, or reports it "
                                + "could not.",
                        ],
                    ],
                    "required": ["bundlePath", "format", "outputPath"],
                ]),
            ToolDefinition(
                name: "snitt_diagnostics_export",
                description: "Write a support bundle — recent app logs, app/CLI versions, "
                           + "permission states, recent agent session history, and (only if "
                           + "the user has opted in) redacted summaries of Snitt's own crash "
                           + "reports — to a JSON file. Contains no window titles, file "
                           + "paths, or input detail. Use this to hand a person something to "
                           + "attach to a support thread, or to see whether Screen Recording "
                           + "is granted.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "outputPath": [
                            "type": "string",
                            "description": "Where to write the diagnostics JSON file",
                        ],
                    ],
                    "required": ["outputPath"],
                ]),
        ]
    }

    /// - Parameter workingDirectory: The directory a relative `bundlePath`/
    ///   `outputPath` is resolved against. Defaults to this process's own
    ///   cwd, which IS the calling MCP client's cwd in production — `snitt-mcp`
    ///   is a subprocess launched fresh per client over stdio, the same
    ///   relationship `snitt-cli`'s own default has to its caller (see
    ///   `requestBody(for:currentDirectory:)` in `Sources/snitt-cli/main.swift`).
    ///   A test injects an explicit value here instead of mutating the real
    ///   process cwd with `chdir` — the property under test is that a
    ///   relative path resolves against the CALLER's directory, and this
    ///   parameter names that directory directly rather than needing a
    ///   round trip through `getcwd`/`chdir`, which is process-global,
    ///   mutable state shared with every other test in the same test bundle.
    public static func request(forTool name: String,
                               arguments: [String: Any],
                               workingDirectory: String = FileManager.default.currentDirectoryPath
                               ) -> Result<AutomationRequest.Body, MCPBridgeError> {
        switch name {
        case "snitt_list_targets":
            return .success(.listTargets)

        case "snitt_status":
            return .success(.status)

        case "snitt_start_recording":
            var options = StartOptions()

            // ConsentPolicy.evaluate checks displayID before bundleIdentifier
            // and returns as soon as a display request is permitted, never
            // consulting bundleIdentifier at all when displayID is present.
            // Mirror that precedence here rather than picking arbitrarily, so
            // a request naming both is decided the same way on both frontends.
            if let rawDisplay = arguments["displayID"] {
                guard let displayID = displayID(from: rawDisplay) else {
                    return .failure(MCPBridgeError(
                        "displayID must be a whole number between 0 and \(UInt32.max)"))
                }
                options.displayID = displayID
            } else if let bundleID = arguments["bundleIdentifier"] as? String {
                options.bundleIdentifier = bundleID
                // Optional, and only meaningful with a bundle identifier — a
                // window id alone would name a window whose app Snitt has not
                // been asked to record.
                if let rawWindow = arguments["windowID"] {
                    guard let windowID = displayID(from: rawWindow) else {
                        return .failure(MCPBridgeError(
                            "windowID must be a whole number between 0 and \(UInt32.max)"))
                    }
                    options.windowID = windowID
                }
            } else {
                return .failure(MCPBridgeError(
                    "snitt_start_recording requires either bundleIdentifier or displayID"))
            }

            switch booleanValue(arguments["microphone"], parameter: "microphone") {
            case .success(let value): if let value { options.microphone = value }
            case .failure(let error): return .failure(error)
            }
            switch booleanValue(arguments["systemAudio"], parameter: "systemAudio") {
            case .success(let value): if let value { options.systemAudio = value }
            case .failure(let error): return .failure(error)
            }
            if let max = arguments["maxDurationSeconds"] as? Double {
                options.maxDurationSeconds = max
            }
            return .success(.startRecording(options))

        case "snitt_stop_recording":
            guard let session = arguments["sessionId"] as? String else {
                return .failure(MCPBridgeError("snitt_stop_recording requires sessionId"))
            }
            return .success(.stopRecording(sessionID: session))

        case "snitt_add_marker":
            guard let session = arguments["sessionId"] as? String else {
                return .failure(MCPBridgeError("snitt_add_marker requires sessionId"))
            }
            return .success(.mark(sessionID: session, label: arguments["label"] as? String))

        case "snitt_inspect":
            guard let path = arguments["bundlePath"] as? String else {
                return .failure(MCPBridgeError("snitt_inspect requires bundlePath"))
            }
            return .success(.inspect(bundlePath: path))

        case "snitt_report_input":
            guard let session = arguments["sessionId"] as? String else {
                return .failure(MCPBridgeError("snitt_report_input requires sessionId"))
            }
            guard let kind = arguments["kind"] as? String else {
                return .failure(MCPBridgeError("snitt_report_input requires kind"))
            }
            // A keystroke happens at no particular place, so it alone may omit
            // x and y. Every pointer kind still requires them — a click with
            // no position is a click Snitt cannot draw or reason about.
            let isKeystroke = kind == "keystroke"
            if isKeystroke, arguments["label"] != nil {
                return .failure(MCPBridgeError(
                    "A reported keystroke cannot carry a label. Report WHEN you typed, "
                  + "not what — saying what was typed is a claim about content Snitt "
                  + "never saw. Use snitt_add_marker if the moment needs a name."))
            }
            var point: [String: Double] = [:]
            for key in ["x", "y"] {
                switch numericValue(arguments[key], parameter: key) {
                case .success(let value):
                    guard let value else {
                        if isKeystroke { continue }
                        return .failure(MCPBridgeError(
                            "snitt_report_input requires x and y as fractions of the window"))
                    }
                    point[key] = value
                case .failure(let error): return .failure(error)
                }
            }
            return .success(.reportInput(sessionID: session, kind: kind,
                                         x: point["x"], y: point["y"],
                                         label: arguments["label"] as? String))

        case "snitt_screenshot":
            guard let session = arguments["sessionId"] as? String else {
                return .failure(MCPBridgeError("snitt_screenshot requires sessionId"))
            }
            return .success(.screenshot(sessionID: session,
                                        label: arguments["label"] as? String))

        case "snitt_pause_recording", "snitt_resume_recording":
            guard let session = arguments["sessionId"] as? String else {
                return .failure(MCPBridgeError("\(name) requires sessionId"))
            }
            return .success(name == "snitt_pause_recording"
                            ? .pauseRecording(sessionID: session)
                            : .resumeRecording(sessionID: session))

        case "snitt_crop":
            guard let path = arguments["bundlePath"] as? String else {
                return .failure(MCPBridgeError("snitt_crop requires bundlePath"))
            }
            if arguments["reset"] as? Bool == true {
                return .success(.crop(bundlePath: path, rect: nil))
            }
            var rect: [String: Double] = [:]
            for key in ["x", "y", "width", "height"] {
                switch numericValue(arguments[key], parameter: key) {
                case .success(let value):
                    guard let value else {
                        // All four or none. A partial rect has no sensible
                        // default: zeros crop to nothing, full-frame silently
                        // ignores what was asked for.
                        return .failure(MCPBridgeError(
                            "snitt_crop needs x, y, width and height together "
                          + "(fractions of the frame, 0-1), or reset: true."))
                    }
                    rect[key] = value
                case .failure(let error): return .failure(error)
                }
            }
            guard rect["width"]! > 0, rect["height"]! > 0 else {
                return .failure(MCPBridgeError(
                    "snitt_crop needs width and height greater than 0. "
                  + "Use reset: true to remove a crop."))
            }
            return .success(.crop(bundlePath: path,
                                  rect: CropRect(x: rect["x"]!, y: rect["y"]!,
                                                 width: rect["width"]!, height: rect["height"]!)))

        case "snitt_auto_deep_trim":
            guard let path = arguments["bundlePath"] as? String else {
                return .failure(MCPBridgeError("snitt_auto_deep_trim requires bundlePath"))
            }
            var criteria = DeepTrimCriteria.preset(.default)
            if let raw = arguments["preset"] {
                guard let name = raw as? String, let preset = DeepTrimPreset(rawValue: name) else {
                    return .failure(MCPBridgeError(
                        "snitt_auto_deep_trim preset must be one of: "
                      + DeepTrimPreset.allCases.map(\.rawValue).joined(separator: ", ")))
                }
                criteria = .preset(preset)
            }
            // Each setting overrides one part of the preset rather than
            // replacing it, matching the CLI: an agent asking for "aggressive
            // but keep two seconds around clicks" should not have to restate
            // the other four.
            let overrides: [(String, (inout DeepTrimCriteria, Double) -> Void)] = [
                ("minSpan", { $0.minimumSpan = $1 }),
                ("audioSilence", { $0.audioSilenceFraction = Float($1) }),
                ("frameStillness", { $0.frameStillnessThreshold = $1 }),
                ("inputPadding", { $0.inputPadding = $1 }),
                ("readingTime", { $0.subtitleReadingTime = $1 }),
            ]
            for (key, apply) in overrides {
                switch numericValue(arguments[key], parameter: key) {
                case .failure(let error): return .failure(error)
                case .success(let value):
                    guard let value else { continue }
                    // Negative seconds and negative thresholds are nonsense
                    // that would silently widen or disable a criterion.
                    guard value >= 0 else {
                        return .failure(MCPBridgeError(
                            "snitt_auto_deep_trim \(key) must be zero or greater"))
                    }
                    apply(&criteria, value)
                }
            }
            return .success(.autoDeepTrim(
                bundlePath: PathResolver.resolve(path, workingDirectory: workingDirectory),
                criteria: criteria))

        case "snitt_trim":
            guard let path = arguments["bundlePath"] as? String else {
                return .failure(MCPBridgeError("snitt_trim requires bundlePath"))
            }
            let start: Double?
            switch numericValue(arguments["start"], parameter: "start") {
            case .success(let value): start = value
            case .failure(let error): return .failure(error)
            }
            let end: Double?
            switch numericValue(arguments["end"], parameter: "end") {
            case .success(let value): end = value
            case .failure(let error): return .failure(error)
            }
            let auto: Bool
            switch booleanValue(arguments["autoTrim"], parameter: "autoTrim") {
            case .success(let value): auto = value ?? false
            case .failure(let error): return .failure(error)
            }
            // A trim with neither a range nor autoTrim would write an empty
            // edit and report success — the same confidently-wrong failure
            // the CLI's parser refuses (§8).
            guard auto || start != nil || end != nil else {
                return .failure(MCPBridgeError(
                    "snitt_trim requires either start/end or autoTrim: true. "
                  + "Writing no cuts would silently do nothing."))
            }
            // A backwards or empty range is meaningless; catching it here,
            // where the caller can still fix the request, beats deferring to
            // whatever AVFoundation does with a degenerate composition.
            if let start, let end, start >= end {
                return .failure(MCPBridgeError(
                    "snitt_trim requires end (\(end)) to be after start (\(start))"))
            }
            return .success(.trim(bundlePath: PathResolver.resolve(path, workingDirectory: workingDirectory),
                                   start: start, end: end, auto: auto))

        case "snitt_export":
            guard let path = arguments["bundlePath"] as? String else {
                return .failure(MCPBridgeError("snitt_export requires bundlePath"))
            }
            guard let format = arguments["format"] as? String else {
                return .failure(MCPBridgeError("snitt_export requires format"))
            }
            // Opening the gif seam must not open it to everything else.
            guard format == "mp4" || format == "gif" else {
                return .failure(MCPBridgeError(
                    "Unsupported export format: \(format). Only mp4 and gif are supported."))
            }
            guard let outputPath = arguments["outputPath"] as? String else {
                return .failure(MCPBridgeError("snitt_export requires outputPath"))
            }
            let scale: Double
            switch numericValue(arguments["scale"], parameter: "scale") {
            case .success(let value): scale = value ?? 1.0
            case .failure(let error): return .failure(error)
            }
            // A zero or negative scale produces a degenerate composition;
            // refuse it here rather than let AVFoundation fail (or worse,
            // not fail) further down the pipe.
            guard scale > 0 else {
                return .failure(MCPBridgeError(
                    "snitt_export requires scale to be greater than 0, got \(scale)"))
            }
            let chapters: Bool
            switch booleanValue(arguments["chapters"], parameter: "chapters") {
            case .success(let value): chapters = value ?? false
            case .failure(let error): return .failure(error)
            }
            // maxSize arrives as a JSON STRING ("10MB"), unlike scale — a
            // number. Absent keeps no limit; present-but-unparseable fails
            // the call by name rather than silently exporting unbounded
            // (§8) — a `?? nil` fallback here would make an oversized
            // export look like a success.
            var maxSizeBytes: Int?
            if let rawMaxSize = arguments["maxSize"] {
                guard let text = rawMaxSize as? String else {
                    return .failure(MCPBridgeError(
                        "snitt_export requires maxSize to be a string like \"10MB\", got \(rawMaxSize)"))
                }
                guard let bytes = ByteSize.parse(text) else {
                    return .failure(MCPBridgeError(
                        "snitt_export requires maxSize to look like \"10MB\", got \"\(text)\""))
                }
                maxSizeBytes = bytes
            }
            return .success(.export(bundlePath: PathResolver.resolve(path, workingDirectory: workingDirectory),
                                     format: format,
                                     outputPath: PathResolver.resolve(outputPath, workingDirectory: workingDirectory),
                                     scale: scale, chapters: chapters,
                                     subtitles: (arguments["subtitles"] as? Bool) ?? false,
                                     maxSizeBytes: maxSizeBytes))

        case "snitt_diagnostics_export":
            guard let outputPath = arguments["outputPath"] as? String else {
                return .failure(MCPBridgeError("snitt_diagnostics_export requires outputPath"))
            }
            // `.diagnostics`'s own doc comment declares `outputPath` arrives
            // already resolved against the CALLER's working directory —
            // `snitt-cli` honours that (`PathResolver.resolve`, done before
            // the request is sent), and so does this bridge, for `bundlePath`
            // and `outputPath` on every tool that carries one (`snitt_trim`,
            // `snitt_export`, `snitt_diagnostics_export`) — otherwise a
            // relative path from an MCP client would resolve against
            // whatever cwd `Snitt.app`/the automation host happened to have,
            // not the caller's.
            return .success(.diagnostics(outputPath: PathResolver.resolve(outputPath, workingDirectory: workingDirectory)))

        default:
            return .failure(MCPBridgeError("Unknown tool: \(name)"))
        }
    }

    /// Converts an MCP argument value to a `UInt32` display id.
    ///
    /// The CLI parses `--display` straight into `UInt32`; JSON numbers arrive
    /// here as `Int`, `Double`, or `NSNumber` depending on the decoder. All three
    /// bridge to `NSNumber` on Darwin, so that is the single conversion path.
    /// Anything fractional or outside `UInt32`'s range is refused rather than
    /// silently truncated — a wrong display id would record the wrong thing.
    private static func displayID(from value: Any) -> UInt32? {
        // A stray `true`/`false` should be refused rather than read as 1/0.
        // `isJSONBoolean` — not `value is Bool` — is what actually tells a
        // real JSON boolean apart from an NSNumber holding 0 or 1: see its
        // doc comment.
        guard !isJSONBoolean(value), let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.truncatingRemainder(dividingBy: 1) == 0 else { return nil }
        guard double >= 0, double <= Double(UInt32.max) else { return nil }
        return UInt32(double)
    }

    /// Tells a genuine JSON boolean apart from an `NSNumber` that merely
    /// holds `0` or `1`.
    ///
    /// `value is Bool` is the wrong tool for this: `JSONSerialization`
    /// decodes every JSON number — including plain 64-bit integers like `1`
    /// — to `NSNumber`, and Swift's dynamic cast from `Any` holding an
    /// `NSNumber` to `Bool` **succeeds whenever the number's value is
    /// exactly 0 or 1**, regardless of whether the underlying value came
    /// from a JSON `true`/`false` or a JSON `1`. That made `numericValue`
    /// reject the single most common value an agent sends — `"scale": 1` —
    /// while accepting `"scale": 2`. `CFBooleanGetTypeID()` checks the
    /// actual CoreFoundation type: a real JSON boolean decodes to the
    /// `CFBoolean` singleton, an integer never does, so this discriminates
    /// correctly regardless of the numeric value involved.
    private static func isJSONBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    /// Converts an optional MCP argument value to a `Double`, distinguishing
    /// "absent" (legitimate — the caller gets `nil` and keeps whatever
    /// default applies) from "present but not a valid number" (a caller
    /// error that must fail the whole request, not silently fall back to a
    /// default).
    ///
    /// JSON numbers arrive as `Int`, `Double`, or `NSNumber` depending on the
    /// decoder, and all three bridge to `NSNumber` on Darwin — the same
    /// reasoning as `displayID(from:)`. A JSON `bool` bridges to `NSNumber`
    /// too and must be rejected explicitly, or `true`/`false` would be read
    /// as `1`/`0` instead of refused — see `isJSONBoolean` for why that
    /// check cannot be `value is Bool`. NaN and infinity are rejected
    /// outright: they cannot come from `JSONSerialization` today, but
    /// nothing stops a future caller from constructing arguments directly,
    /// and a "valid" non-finite scale or bound would be exactly this bug's
    /// failure mode again.
    private static func numericValue(_ value: Any?,
                                     parameter: String) -> Result<Double?, MCPBridgeError> {
        guard let value else { return .success(nil) }
        guard !isJSONBoolean(value), let number = value as? NSNumber else {
            return .failure(MCPBridgeError(
                "\(parameter) must be a number, got \(value)"))
        }
        let double = number.doubleValue
        guard double.isFinite else {
            return .failure(MCPBridgeError(
                "\(parameter) must be a finite number, got \(double)"))
        }
        return .success(double)
    }

    /// Converts an optional MCP argument value to a `Bool`, with the same
    /// absent-versus-invalid discipline `numericValue` applies to numbers.
    ///
    /// Two earlier fix rounds hardened `numericValue`/`displayID(from:)` to
    /// tell "absent" (keep the default) apart from "present but not a valid
    /// number" (fail the call), but `autoTrim` and `chapters` stayed on
    /// `arguments["…"] as? Bool ?? false`. `JSONSerialization` decodes a
    /// stray `"true"` (a JSON string, not a boolean) to an `NSString`, which
    /// `as? Bool` fails on — silently, into the `?? false` default — so
    /// `{"chapters": "true"}` exported successfully with no chapters and no
    /// error, indistinguishable from a recording that genuinely had none.
    /// `{"autoTrim": "true"}` alongside `start`/`end` silently ran a range
    /// trim instead of auto-trim. Both are exactly the confidently-wrong
    /// outcome §8 forbids.
    ///
    /// Leniency toward NUMBERS is kept deliberately: `chapters: 1` must keep
    /// reading as `true`, the same way `scale: 1` reads as a number and not
    /// a boolean (`isJSONBoolean` is what makes both directions correct at
    /// once — a genuine JSON `bool` is never mistaken for the number `0`/`1`,
    /// and a genuine `0`/`1` is never mistaken for a `bool`). What must NOT
    /// be lenient is silence toward a value of some other type entirely.
    private static func booleanValue(_ value: Any?,
                                     parameter: String) -> Result<Bool?, MCPBridgeError> {
        guard let value else { return .success(nil) }
        if isJSONBoolean(value), let number = value as? NSNumber {
            return .success(number.boolValue)
        }
        if let number = value as? NSNumber {
            switch number.doubleValue {
            case 0: return .success(false)
            case 1: return .success(true)
            default:
                return .failure(MCPBridgeError(
                    "\(parameter) must be a boolean, got \(number)"))
            }
        }
        return .failure(MCPBridgeError(
            "\(parameter) must be a boolean, got \(value)"))
    }
}
