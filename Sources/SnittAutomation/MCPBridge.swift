import Foundation
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
    public static func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "snitt_list_targets",
                description: "List windows and displays that can be recorded.",
                inputSchema: ["type": "object", "properties": [String: Any]()]),
            ToolDefinition(
                name: "snitt_start_recording",
                description: "Start recording a window belonging to an application. "
                           + "Returns a session id used to stop it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bundleIdentifier": [
                            "type": "string",
                            "description": "Bundle id of the app whose window to record. "
                                + "Preferred over displayID — window recording needs no "
                                + "extra opt-in.",
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
                description: "Cut dead time from a recording by editing its edit decision "
                           + "list. Never touches capture.mov. Provide either an explicit "
                           + "start/end range or autoTrim to trim bookends from a human "
                           + "recording's input events.",
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
                            "description": "Trim bookends using recorded input events. Only "
                                + "works on human recordings — agent recordings have no "
                                + "input events and are refused.",
                        ],
                    ],
                    "required": ["bundlePath"],
                ]),
            ToolDefinition(
                name: "snitt_export",
                description: "Render the trimmed recording to a movie file and return a "
                           + "manifest — duration, dimensions, byte size, chapters — that "
                           + "an agent can quote without watching the file.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bundlePath": [
                            "type": "string",
                            "description": "Path printed by snitt_stop_recording",
                        ],
                        "format": [
                            "type": "string",
                            "description": "Only \"mp4\" is supported in this milestone.",
                        ],
                        "outputPath": ["type": "string", "description": "Where to write the movie"],
                        "scale": ["type": "number", "default": 1.0,
                                  "description": "Pixel-dimension multiplier"],
                        "chapters": ["type": "boolean", "default": false,
                                     "description": "Write a .vtt beside the output from the bundle's markers"],
                    ],
                    "required": ["bundlePath", "format", "outputPath"],
                ]),
        ]
    }

    public static func request(forTool name: String,
                               arguments: [String: Any]) -> Result<AutomationRequest.Body, MCPBridgeError> {
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
            } else {
                return .failure(MCPBridgeError(
                    "snitt_start_recording requires either bundleIdentifier or displayID"))
            }

            if let mic = arguments["microphone"] as? Bool { options.microphone = mic }
            if let sys = arguments["systemAudio"] as? Bool { options.systemAudio = sys }
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
            let auto = arguments["autoTrim"] as? Bool ?? false
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
            return .success(.trim(bundlePath: path, start: start, end: end, auto: auto))

        case "snitt_export":
            guard let path = arguments["bundlePath"] as? String else {
                return .failure(MCPBridgeError("snitt_export requires bundlePath"))
            }
            guard let format = arguments["format"] as? String else {
                return .failure(MCPBridgeError("snitt_export requires format"))
            }
            // gif is M3d — a separate encoder entirely. Accepting it here
            // would silently write an mp4 to a path that says .gif.
            guard format == "mp4" else {
                return .failure(MCPBridgeError(
                    "Unsupported export format: \(format). Only mp4 is supported in this "
                  + "milestone; gif is planned for a later release."))
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
            let chapters = arguments["chapters"] as? Bool ?? false
            return .success(.export(bundlePath: path, format: format, outputPath: outputPath,
                                     scale: scale, chapters: chapters))

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
}
