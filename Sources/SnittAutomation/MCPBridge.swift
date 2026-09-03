import Foundation

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
                            "description": "Bundle id of the app whose window to record",
                        ],
                        "microphone": ["type": "boolean", "default": false],
                        "systemAudio": ["type": "boolean", "default": true],
                        "maxDurationSeconds": ["type": "number"],
                    ],
                    "required": ["bundleIdentifier"],
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
            guard let bundleID = arguments["bundleIdentifier"] as? String else {
                return .failure(MCPBridgeError("snitt_start_recording requires bundleIdentifier"))
            }
            var options = StartOptions(bundleIdentifier: bundleID)
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

        default:
            return .failure(MCPBridgeError("Unknown tool: \(name)"))
        }
    }
}
