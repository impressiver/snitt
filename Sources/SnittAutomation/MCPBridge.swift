// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

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
    /// The machine-readable half, so a bridge refusal is something an agent
    /// can BRANCH on rather than a sentence it must read (D106).
    ///
    /// `AutomationError.Code`'s own doc comment says "an agent branches on
    /// this, never on `message`", and until D106 the largest class of real
    /// agent mistakes (sending the wrong arguments) was the one class that
    /// never reached the taxonomy: an `AutomationError` rendered code-prefixed
    /// and with `structuredContent`, while everything built here rendered as
    /// bare text with `isError: true` and nothing to branch on.
    ///
    /// Defaulted rather than demanded at every construction site on purpose.
    /// Every refusal this type exists for is the same answer: the call was
    /// wrong, change it and send it again. Making forty-odd sites repeat
    /// it would add a way to get it wrong, not information. A site that
    /// genuinely means something else passes it.
    public let code: AutomationError.Code

    public init(_ message: String, code: AutomationError.Code = .invalidArguments) {
        self.message = message
        self.code = code
    }

    /// The same value the app's own refusals travel in, so a frontend renders
    /// a bridge error and an app error through one path rather than two that
    /// can drift (§4.8).
    public var automationError: AutomationError {
        AutomationError(code: code, message: message)
    }
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
    /// What the server is FOR, as against what each tool does.
    ///
    /// S5's second problem: a tool list answers "how do I call this" and never
    /// "why would I record my screen". An agent that never considers making a
    /// demo never reads the schema, so this is the only text that gets a
    /// chance to change its mind.
    ///
    /// S5 also names the hazard in writing it: prose drifts from the surface it
    /// describes, and §10's version handshake covers the wire protocol, not the
    /// documentation. `ServerInstructionsTests` is that missing guard —
    /// every tool named below must exist, the workflow tools must all be
    /// named, and the specific claims that went stale before are pinned.
    public static let serverInstructions = """
        Snitt records a macOS window to a .snitt bundle, so you can show work \
        instead of describing it: a demo attached to a pull request, a bug \
        reproduced on video, a before-and-after.

        Snitt films; it does not click or type. Drive the UI with your own \
        tools and use these to wrap a recording around that work. You do not \
        need to ask anyone to open Snitt first — if it is not running, calling \
        one of these starts it.

        The loop:

        1. snitt_start_recording. Recording is scoped to one application's \
           window by default — prefer bundleIdentifier over displayID, which \
           additionally requires a person to have turned on full-display agent \
           recording.
        2. LOOK, before you do anything else: snitt_screenshot with \
           inline: true hands you the frame itself. It is the only way to find \
           out that you are filming the wrong window, that a dialog is sitting \
           over the target, or that the picture is black, and all of that is \
           still fixable now and is not fixable later. It is also where the \
           crop at step 6 comes from: note what the chrome carries and where \
           it sits, in pixels of the image you were handed, and pass that \
           image's own width and height back as frameWidth/frameHeight.
        3. Do the work. Call snitt_report_input as you go: your clicks and \
           keystrokes never reach the screen, so without this the recording \
           shows things changing with no visible cause, which is what makes an \
           agent demo unwatchable. It also earns you step 5: a take's ends are \
           found from input events, and reported input counts.
        4. snitt_mark at each step a reviewer should be able to jump to.
        5. snitt_stop_recording, then snitt_auto_deep_trim. One call: it takes \
           the setup and teardown off the ends AND removes the gaps in between, \
           the seconds spent waiting for a page to load. Non-destructive, \
           reversible, and safe to run twice. snitt_trim is still there when \
           you want to name an explicit start and end instead.
        6. snitt_crop if the window's chrome carries anything that should not \
           be shared. A browser's tab strip puts the titles of every other open \
           tab into every frame. Give the rectangle in pixels of the screenshot \
           you looked at, with frameWidth/frameHeight naming that image's size.
        7. Say something. snitt_narrate writes a line at a moment in the \
           recording: you have no voice, so a written line is your \
           microphone. snitt_transcript reads back everything the recording \
           says, written or spoken. A written line is CAPTIONED rather than \
           spoken, so it reaches a viewer only if you also pass captions to \
           snitt_export.
        8. snitt_inspect, then snitt_export. You cannot watch what you \
           recorded, so snitt_inspect is how you find out what you made, and \
           its output is what to quote when describing the demo. Pass maxSize \
           to snitt_export when the file is going somewhere with an attachment \
           limit, and captions when the recording has anything to say.

        snitt_list_recordings shows what is already on disk: use it when you \
        have lost a bundle path, and after a session that ended badly. A \
        recording marked "capped" was force-stopped because the session that \
        started it went away, so it is a full-resolution video nobody has \
        watched.

        A person at the machine can see and stop any recording at any time.
        """

    /// Tool names this bridge still answers to, mapped to what they are now
    /// called.
    ///
    /// A rename is a breaking change to a public surface, and the breakage is
    /// not symmetrical: an MCP host caches the tool list it was handed at
    /// `initialize` and may go on calling the old name for the life of that
    /// session, while a `tools/list` a moment later advertises the new one.
    /// Answering to both costs one dictionary lookup and removes the whole
    /// class of failure; the old names are deliberately NOT advertised, so a
    /// caller reading the list today learns one name per verb.
    ///
    /// `snitt_add_marker` was the only verb in the surface that matched
    /// neither the protocol's `.mark` nor the CLI's `record mark`;
    /// `snitt_estimate_export` was the only one that did not match its own CLI
    /// verb, `snitt estimate`.
    public static let toolAliases: [String: String] = [
        "snitt_add_marker": "snitt_mark",
        "snitt_estimate_export": "snitt_estimate",
    ]

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
                        "microphone": [
                            "type": "boolean",
                            "default": false,
                            "description": "Record the microphone too. Off by "
                                + "default, and worth leaving off unless someone is "
                                + "actually narrating: a mic that is on records "
                                + "whatever is said in the room, and nobody in the "
                                + "room is expecting to be recorded by you. Speech "
                                + "is transcribed on device.",
                        ],
                        "systemAudio": [
                            "type": "boolean",
                            "default": true,
                            "description": "Record what the machine itself plays: a "
                                + "video in the page, an alert, anything with sound. "
                                + "On by default, because a demo that plays a video "
                                + "in silence reads as broken rather than as quiet.",
                        ],
                        "maxDurationSeconds": [
                            "type": "number",
                            "description": "Stop on your own after this many seconds. "
                                + "Time spent paused counts toward it. This is a "
                                + "safety net rather than a plan: an agent that dies "
                                + "before it calls snitt_stop_recording leaves the "
                                + "recording running and the disk filling, so set it "
                                + "to a generous upper bound on the work you are about "
                                + "to do. No cap unless you set one.",
                        ],
                        "vocabulary": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Words you are about to SAY that a general "
                                + "speech model has never heard — symbol names, file "
                                + "names, product names. Biases transcription toward "
                                + "them without restricting to them, so a term you "
                                + "never say costs nothing and it is worth listing "
                                + "generously. Every one it mishears is a correction "
                                + "somebody makes by hand. Up to 100, and terms are "
                                + "capped at 60 characters; the response reports "
                                + "`vocabularyDropped` when anything you sent did not "
                                + "reach the recogniser.",
                        ],
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
                           + "the recording's clock so it can be drawn. GIVE THE PIXELS "
                           + "YOU ALREADY HAVE: pass frameWidth and frameHeight naming "
                           + "the window or the snitt_screenshot image you measured x "
                           + "and y in, and Snitt does the division. Without them x and "
                           + "y are read as fractions of the recorded window (0-1, "
                           + "origin top-left). Either way a point outside the frame is "
                           + "refused rather than quietly moved to the edge. Snitt does "
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
                        "x": ["type": "number",
                              "description": "Across the window: pixels when frameWidth "
                                  + "is given, otherwise a fraction (0-1)."],
                        "y": ["type": "number",
                              "description": "Down the window: pixels when frameHeight "
                                  + "is given, otherwise a fraction (0-1)."],
                        "frameWidth": [
                            "type": "number",
                            "description": "Width, in the same units as x, of the picture "
                                + "you measured in, the recorded window's own width or "
                                + "the width of the snitt_screenshot image you are "
                                + "looking at. Given with frameHeight, x and y are read "
                                + "as pixels instead of fractions.",
                        ],
                        "frameHeight": [
                            "type": "number",
                            "description": "Height of that same picture. Required "
                                + "alongside frameWidth, and refused without it: half a "
                                + "frame size cannot say what the other axis means.",
                        ],
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
                        "inline": [
                            "type": "boolean",
                            "description": "Return the frame ITSELF, not just a path to it. "
                                + "Pass true when you actually need to look — a path is of "
                                + "no use to you unless your host happens to read files. "
                                + "The image is embedded in the response, which means it "
                                + "goes wherever your model runs: ask for it when you need "
                                + "to see, not by habit. Downscaled to 1280px on its "
                                + "longest edge. Off by default.",
                        ],
                    ],
                    "required": ["sessionId"],
                ]),
            ToolDefinition(
                name: "snitt_status",
                description: "Report whether a recording is currently running, and "
                           + "which permissions a person has granted. Call it FIRST on "
                           + "a cold start: the `consent` block says whether agent "
                           + "recording is switched on at all, whether a whole display "
                           + "may be recorded, and whether unattended recording is in "
                           + "force, so you can choose a target you are allowed to "
                           + "record instead of finding out from a consent_required "
                           + "failure. This tool itself is never refused.",
                inputSchema: ["type": "object", "properties": [String: Any]()]),
            ToolDefinition(
                // Renamed from snitt_add_marker, which was the one verb in this
                // surface that matched neither the protocol's `.mark` nor the
                // CLI's `record mark`. The old name still maps, so a host
                // holding a cached tool list keeps working; only the advertised
                // name changed. See `markerToolAliases`.
                name: "snitt_mark",
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
                name: "snitt_list_recordings",
                description: "List the .snitt bundles sitting in Snitt's output "
                           + "directory, newest first: where each one is, how big, how "
                           + "old, and how it ended. Use it to find a recording you "
                           + "lost track of, and to notice the ones you never meant to "
                           + "keep. A recording marked \"capped\" was force-stopped "
                           + "because the session that started it ran past its limit or "
                           + "went away, so it is usually a full-resolution video "
                           + "nobody has watched. Snitt does not delete anything: this "
                           + "tells you what is there and where, and removing a bundle "
                           + "is yours to do.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "limit": [
                            "type": "number",
                            "description": "How many to return, newest first. The answer "
                                + "always says how many exist in total, so a truncated "
                                + "list reads as truncated. Defaults to all of them.",
                        ],
                    ],
                ]),
            ToolDefinition(
                name: "snitt_transcript",
                description: "Read what a recording SAYS, as lines with their times. "
                           + "Speech is transcribed on the device after a recording "
                           + "stops, and this is how you find out what is in it, since "
                           + "you cannot listen to it. Each line says whether it was "
                           + "HEARD by the recogniser or WRITTEN with snitt_narrate, and "
                           + "whether its audio track is muted, a muted line is in the "
                           + "transcript and in nobody's video. Times are seconds from "
                           + "the start of the recording, the same clock snitt_inspect "
                           + "prints marker times on.",
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
                name: "snitt_editor_open",
                description: "Open a recording in Snitt's editor, on screen. Use this "
                           + "when you want the EDITING to be visible — filming a demo "
                           + "of Snitt itself, or letting a person watch what you "
                           + "change. Once it is open, snitt_trim, snitt_crop and "
                           + "snitt_narrate land in that window instead of writing the "
                           + "file behind it, so a person sees each edit happen and can "
                           + "undo it. You may only open a recording an agent made: "
                           + "opening someone else's puts it on their screen, which "
                           + "Snitt refuses. Nothing else here opens a window, so call "
                           + "this first.",
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
                name: "snitt_editor_play",
                description: "Start playback in an open editor window. Returns where "
                           + "the playhead actually is, because you cannot watch the "
                           + "window. Fails if the recording is not open — call "
                           + "snitt_editor_open first; Snitt will not open a window as "
                           + "a side effect of being told to play.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bundlePath": ["type": "string", "description": "The open recording"],
                    ],
                    "required": ["bundlePath"],
                ]),
            ToolDefinition(
                name: "snitt_editor_pause",
                description: "Stop playback in an open editor window, leaving the "
                           + "playhead where it is.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bundlePath": ["type": "string", "description": "The open recording"],
                    ],
                    "required": ["bundlePath"],
                ]),
            ToolDefinition(
                name: "snitt_editor_seek",
                description: "Move the playhead in an open editor window. Seconds are "
                           + "OUTPUT time: the recording with its cuts already removed, "
                           + "which is what a person watching sees and what the "
                           + "timeline reads. That is NOT the same as source time once "
                           + "you have trimmed, so seek after trimming, not before, or "
                           + "you will land somewhere else.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bundlePath": ["type": "string", "description": "The open recording"],
                        "toSeconds": [
                            "type": "number",
                            "description": "Output seconds from the start of the edit",
                        ],
                    ],
                    "required": ["bundlePath", "toSeconds"],
                ]),
            ToolDefinition(
                name: "snitt_editor_select",
                description: "Highlight a range on the timeline of an open editor "
                           + "window, the way a person's drag does. Use it to SHOW what "
                           + "you are about to cut before you cut it, which is the "
                           + "difference between a demo a viewer can follow and one "
                           + "where things vanish. Pass neither end to clear the "
                           + "selection. The selection is view state: it is never "
                           + "written into the recording, and a later trim that removes "
                           + "the selected range clears it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bundlePath": ["type": "string", "description": "The open recording"],
                        "fromSeconds": [
                            "type": "number",
                            "description": "Output seconds. Omit both ends to clear.",
                        ],
                        "toSeconds": [
                            "type": "number",
                            "description": "Output seconds, after fromSeconds",
                        ],
                    ],
                    "required": ["bundlePath"],
                ]),
            ToolDefinition(
                name: "snitt_editor_cut",
                description: "Remove the selected range from an open recording, the "
                           + "way pressing Delete does. This is what snitt_editor_select "
                           + "is FOR: select the span you want gone, then cut it, and a "
                           + "person watching sees both halves happen. It is the only "
                           + "way to remove an INTERIOR span — snitt_trim sets the range "
                           + "to KEEP, so it can only take material off the ends, and "
                           + "snitt_auto_deep_trim finds dead air rather than a span you "
                           + "chose. Fails if nothing is selected, rather than reporting "
                           + "a success that changed nothing. Undoable as one step.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bundlePath": ["type": "string", "description": "The open recording"],
                    ],
                    "required": ["bundlePath"],
                ]),
            ToolDefinition(
                name: "snitt_narrate",
                description: "Write a line of narration into a recording at a moment in "
                           + "it. This is how you say something on a demo: you have no "
                           + "voice, so a written line is your microphone. It is "
                           + "CAPTIONED, NOT SPOKEN, Snitt does not synthesise speech, "
                           + "so the line reaches a viewer only if the export draws "
                           + "captions. Pass captions: true to snitt_export, or the "
                           + "words sit in the bundle and appear on nobody's screen. The "
                           + "line joins the transcript beside anything the recogniser "
                           + "heard, marked as written so a person can tell them apart.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bundlePath": [
                            "type": "string",
                            "description": "Path printed by snitt_stop_recording",
                        ],
                        "text": [
                            "type": "string",
                            "description": "The line to say. A sentence or two, it is "
                                + "timed at reading speed and drawn as a caption, so a "
                                + "paragraph stays on screen over the rest of the demo.",
                        ],
                        "atSeconds": [
                            "type": "number",
                            "description": "Where the line belongs, in seconds from the "
                                + "START OF THE RECORDING, not from the start of the "
                                + "trimmed output. That is the clock snitt_inspect "
                                + "reports marker times on and snitt_screenshot reports "
                                + "its own on, so a moment you already have a handle on "
                                + "can be used as it is. Trimming does not move it.",
                        ],
                    ],
                    "required": ["bundlePath", "text", "atSeconds"],
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
                           + "demo shows only what matters. GIVE THE PIXELS YOU "
                           + "ALREADY HAVE: pass frameWidth and frameHeight naming "
                           + "the snitt_screenshot image you worked the rectangle out "
                           + "from, and x/y/width/height are read as pixels in that "
                           + "image. Without them they are fractions of the frame "
                           + "(0-1). A rectangle that runs off the edge is refused "
                           + "rather than quietly pulled back to it. Returns the pixel "
                           + "dimensions the export will have.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bundlePath": [
                            "type": "string",
                            "description": "Path printed by snitt_stop_recording",
                        ],
                        "x": ["type": "number",
                              "description": "Left edge: pixels when frameWidth is "
                                  + "given, otherwise a fraction of the frame (0-1)"],
                        "y": ["type": "number",
                              "description": "Top edge: pixels when frameHeight is "
                                  + "given, otherwise a fraction of the frame (0-1)"],
                        "width": ["type": "number",
                                  "description": "Width, in the same units as x"],
                        "height": ["type": "number",
                                   "description": "Height, in the same units as y"],
                        "frameWidth": [
                            "type": "number",
                            "description": "Width of the picture you measured the "
                                + "rectangle in, the snitt_screenshot image you looked "
                                + "at, whose own size you know. Snitt converts; the "
                                + "stored crop stays a fraction, so it survives an "
                                + "export at any scale.",
                        ],
                        "frameHeight": [
                            "type": "number",
                            "description": "Height of that same picture. Required "
                                + "alongside frameWidth, and refused without it.",
                        ],
                        "reset": [
                            "type": "boolean",
                            "description": "Remove an existing crop instead of setting "
                                + "one. Answers with the frame's FULL pixel dimensions, "
                                + "which is also how to ask what they are.",
                        ],
                    ],
                    "required": ["bundlePath"],
                ]),
            ToolDefinition(
                name: "snitt_auto_deep_trim",
                description: "TIDY UP A RECORDING, in one call. Takes the setup and "
                           + "teardown off the ends, and removes the spans in between "
                           + "where nothing happened: no sound, no movement on screen, "
                           + "no input, no marker, nothing being said. Non-destructive: "
                           + "it appends cuts to the edit decision list and never "
                           + "touches capture.mov, so the result is reversible and safe "
                           + "to run before deciding. The gap removal WORKS ON "
                           + "RECORDINGS YOU MADE with no input events at all, because "
                           + "it reads the picture and the audio instead; the ends need "
                           + "input events to bound the take and are simply left alone "
                           + "without them. Running it twice is safe, because the second run "
                           + "proposes nothing already cut. Use it before snitt_export "
                           + "to hand someone a demo without the minutes spent waiting "
                           + "for a page to load. snitt_trim is still there for when "
                           + "you want to name an explicit start and end instead, and "
                           + "its autoTrim does the ends alone.",
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
                        "trimBookends": [
                            "type": "boolean",
                            "default": true,
                            "description": "Also take the setup and teardown off the "
                                + "ends, bounded by the first and last input event the "
                                + "way snitt_trim's autoTrim is. ON by default, because "
                                + "tidying a recording is one intent and it should not "
                                + "cost two calls. Pass false to keep the ends and "
                                + "remove only the gaps in between.",
                        ],
                    ],
                    "required": ["bundlePath"],
                ]),
            ToolDefinition(
                // Renamed from snitt_estimate_export to match the CLI's
                // `snitt estimate`. The old name still maps; see
                // `estimateToolAliases`.
                name: "snitt_estimate",
                description: "Find out how long, how large and what dimensions an "
                           + "export would be, WITHOUT doing it. Costs a two-second "
                           + "encode instead of the whole file. Use it to pick a scale "
                           + "that fits an attachment limit before committing, rather "
                           + "than exporting and discovering. The size is an UPPER "
                           + "BOUND, not a prediction — the real file comes in under "
                           + "it, so a budget you fit here you will fit. Duration and "
                           + "dimensions are exact. mp4 only.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "bundlePath": [
                            "type": "string",
                            "description": "Path printed by snitt_stop_recording",
                        ],
                        "scale": [
                            "type": "number",
                            "description": "Pixel scale to estimate, e.g. 0.5 for half "
                                + "size. Defaults to 1.0.",
                        ],
                        // Declared, and accepting exactly one value, so that a
                        // caller asking for "gif" is TOLD no rather than handed
                        // an mp4 estimate labelled with its own request. The
                        // CLI's `estimate --format` already refuses the same
                        // way in the same words; the MCP surface silently
                        // hardcoded "mp4" instead, which is the §8 shape.
                        "format": [
                            "type": "string",
                            "enum": ["mp4"],
                            "description": "\"mp4\", and only mp4 (issue #160). A GIF's "
                                + "size tracks how much the picture MOVES rather than "
                                + "how long it runs, so a two-second sample says too "
                                + "little about the whole to be worth reporting. Export "
                                + "a gif with maxSize instead and let the exporter fit "
                                + "it.",
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
                        "resolution": [
                            "type": "string",
                            "enum": ExportResolution.allCases.map(\.rawValue),
                            "description": "Output size to target: 1080p, 720p, 540p, "
                                + "480p, 2160p, or source to keep the recording's own "
                                + "dimensions. Never enlarges — asking for more than "
                                + "the recording has keeps what it has. Use "
                                + "snitt_estimate first to see what each costs. "
                                + "Defaults to source.",
                        ],
                        "clicks": [
                            "type": "boolean",
                            "default": true,
                            "description": "Draw a ring where each click you "
                                + "REPORTED happened, so a viewer can see what "
                                + "caused each change. ON by default (D105): only "
                                + "reported clicks can be drawn, the ones you made "
                                + "with snitt_report_input, because a click the OS "
                                + "saw carries no position Snitt can place, so a "
                                + "recording that reported nothing is unaffected and "
                                + "one that reported everything is the demo the "
                                + "reporting was for. Pass false to leave them off.",
                        ],
                        "captions": [
                            "type": "boolean",
                            "description": "Burn the recording's TRANSCRIPT into the "
                                + "picture as captions, what was said, and anything "
                                + "you wrote with snitt_narrate. Not the same thing as "
                                + "\"subtitles\" above, which writes a sidecar file from "
                                + "marker labels: this one is on the video itself and "
                                + "comes from speech. Leave it out to keep whatever this "
                                + "recording is already set to; a person editing it may "
                                + "have turned captions on, and passing nothing does not "
                                + "take them away.",
                        ],
                        "markerBanners": [
                            "type": "boolean",
                            "description": "Draw each marker's label as a banner over the "
                                + "picture at the moment it was placed, so a viewer sees "
                                + "the step names you narrated with snitt_mark. "
                                + "Leave it out to keep this recording's own setting.",
                        ],
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
    public static func request(forTool requestedName: String,
                               arguments: [String: Any],
                               workingDirectory: String = FileManager.default.currentDirectoryPath
                               ) -> Result<AutomationRequest.Body, MCPBridgeError> {
        let name = toolAliases[requestedName] ?? requestedName
        switch name {
        case "snitt_list_targets":
            return .success(.listTargets)

        case "snitt_status":
            return .success(.status)

        case "snitt_start_recording":
            var options = StartOptions()
            // §7's git context is discovered from this, and `StartOptions`'
            // own comment says it is filled by the CLI rather than the app
            // because `Snitt.app`'s directory is `/`. The MCP bridge is the
            // other client and was not filling it, so every agent-driven
            // recording was filed with no git context while every CLI one had
            // it. Set here rather than inside a branch: it is a property of
            // the CALLER, not of which target it chose.
            options.workingDirectory = workingDirectory

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
            if let raw = arguments["vocabulary"] {
                // Refused by name rather than ignored: a caller that sent the
                // wrong shape asked for biasing and would otherwise get a
                // transcript without it and no indication why.
                guard let terms = raw as? [String] else {
                    return .failure(MCPBridgeError(
                        "snitt_start_recording vocabulary must be an array of strings"))
                }
                options.vocabulary = terms
            }
            return .success(.startRecording(options))

        case "snitt_stop_recording":
            guard let session = arguments["sessionId"] as? String else {
                return .failure(MCPBridgeError("snitt_stop_recording requires sessionId"))
            }
            return .success(.stopRecording(sessionID: session))

        case "snitt_mark":
            guard let session = arguments["sessionId"] as? String else {
                return .failure(MCPBridgeError("snitt_mark requires sessionId"))
            }
            return .success(.mark(sessionID: session, label: arguments["label"] as? String))

        case "snitt_inspect":
            guard let path = arguments["bundlePath"] as? String else {
                return .failure(MCPBridgeError("snitt_inspect requires bundlePath"))
            }
            return .success(.inspect(bundlePath: path))

        case "snitt_list_recordings":
            switch numericValue(arguments["limit"], parameter: "limit") {
            case .failure(let error): return .failure(error)
            case .success(let value):
                guard let value else { return .success(.listRecordings(limit: nil)) }
                // Whole and positive. A fractional limit is a caller who does
                // not know what it asked for, and zero or less would return an
                // empty list that reads exactly like an empty directory.
                guard value.truncatingRemainder(dividingBy: 1) == 0, value > 0,
                      value <= Double(Int.max) else {
                    return .failure(MCPBridgeError(
                        "snitt_list_recordings limit must be a whole number above 0"))
                }
                return .success(.listRecordings(limit: Int(value)))
            }

        case "snitt_transcript":
            guard let path = arguments["bundlePath"] as? String else {
                return .failure(MCPBridgeError("snitt_transcript requires bundlePath"))
            }
            return .success(.transcript(
                bundlePath: PathResolver.resolve(path, workingDirectory: workingDirectory)))

        case "snitt_editor_cut":
            guard let path = arguments["bundlePath"] as? String else {
                return .failure(MCPBridgeError("snitt_editor_cut requires bundlePath"))
            }
            return .success(.editorCut(
                bundlePath: PathResolver.resolve(path, workingDirectory: workingDirectory)))

        case "snitt_editor_open", "snitt_editor_play", "snitt_editor_pause":
            guard let path = arguments["bundlePath"] as? String else {
                return .failure(MCPBridgeError("\(name) requires bundlePath"))
            }
            let resolved = PathResolver.resolve(path, workingDirectory: workingDirectory)
            switch name {
            case "snitt_editor_open": return .success(.editorOpen(bundlePath: resolved))
            case "snitt_editor_play": return .success(.editorPlay(bundlePath: resolved))
            default: return .success(.editorPause(bundlePath: resolved))
            }

        case "snitt_editor_seek":
            guard let path = arguments["bundlePath"] as? String else {
                return .failure(MCPBridgeError("snitt_editor_seek requires bundlePath"))
            }
            let seconds: Double
            switch numericValue(arguments["toSeconds"], parameter: "toSeconds") {
            case .failure(let error): return .failure(error)
            case .success(let value):
                guard let value else {
                    return .failure(MCPBridgeError("snitt_editor_seek requires toSeconds"))
                }
                seconds = value
            }
            return .success(.editorSeek(
                bundlePath: PathResolver.resolve(path, workingDirectory: workingDirectory),
                toSeconds: seconds))

        case "snitt_editor_select":
            guard let path = arguments["bundlePath"] as? String else {
                return .failure(MCPBridgeError("snitt_editor_select requires bundlePath"))
            }
            let from: Double?
            let to: Double?
            switch numericValue(arguments["fromSeconds"], parameter: "fromSeconds") {
            case .failure(let error): return .failure(error)
            case .success(let value): from = value
            }
            switch numericValue(arguments["toSeconds"], parameter: "toSeconds") {
            case .failure(let error): return .failure(error)
            case .success(let value): to = value
            }
            return .success(.editorSelect(
                bundlePath: PathResolver.resolve(path, workingDirectory: workingDirectory),
                fromSeconds: from, toSeconds: to))

        case "snitt_narrate":
            guard let path = arguments["bundlePath"] as? String else {
                return .failure(MCPBridgeError("snitt_narrate requires bundlePath"))
            }
            guard let text = arguments["text"] as? String else {
                return .failure(MCPBridgeError("snitt_narrate requires text"))
            }
            // Blank text is refused here rather than written: `AuthoredNarration.words`
            // yields nothing for it, so the call would report a cheerful
            // success having added no line at all, the silent no-op §8
            // forbids, and the one an agent is most likely to hit by
            // interpolating an empty variable.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(MCPBridgeError(
                    "snitt_narrate text must not be blank. An empty line places nothing "
                  + "on the recording and would report success anyway."))
            }
            let atSeconds: Double
            switch numericValue(arguments["atSeconds"], parameter: "atSeconds") {
            case .failure(let error): return .failure(error)
            case .success(let value):
                guard let value else {
                    return .failure(MCPBridgeError(
                        "snitt_narrate requires atSeconds: where in the recording the "
                      + "line belongs, in seconds from its start. Defaulting to 0 would "
                      + "silently anchor every line to the first frame."))
                }
                // Seconds are measured from the start of the recording, so
                // there is no negative time to place a line at.
                guard value >= 0 else {
                    return .failure(MCPBridgeError(
                        "snitt_narrate atSeconds must be zero or greater, got \(value)"))
                }
                atSeconds = value
            }
            return .success(.addNarration(
                bundlePath: PathResolver.resolve(path, workingDirectory: workingDirectory),
                text: text, atSeconds: atSeconds))

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
                  + "never saw. Use snitt_mark if the moment needs a name."))
            }
            let inputFrame: CoordinateFrame?
            switch frameSize(arguments, tool: "snitt_report_input") {
            case .failure(let error): return .failure(error)
            case .success(let value): inputFrame = value
            }
            var point: [String: Double] = [:]
            for key in ["x", "y"] {
                switch numericValue(arguments[key], parameter: key) {
                case .success(let value):
                    guard let value else {
                        if isKeystroke { continue }
                        return .failure(MCPBridgeError(
                            "snitt_report_input requires x and y: pixels if you also "
                          + "give frameWidth and frameHeight, otherwise fractions of "
                          + "the window (0-1)"))
                    }
                    point[key] = value
                case .failure(let error): return .failure(error)
                }
            }
            if let x = point["x"], let y = point["y"] {
                // D105. Divided here, where the caller's own numbers are, and
                // never stored in pixels: the recorded frame may be a different
                // size again, and a fraction is the only form that stays true
                // across all of them.
                switch CoordinateFrame.unitPoint(x: x, y: y, in: inputFrame,
                                                 verb: "snitt_report_input") {
                case .failure(let failure): return .failure(MCPBridgeError(failure.message))
                case .success(let unit):
                    point["x"] = unit.x
                    point["y"] = unit.y
                }
            }
            return .success(.reportInput(sessionID: session, kind: kind,
                                         x: point["x"], y: point["y"],
                                         label: arguments["label"] as? String))

        case "snitt_screenshot":
            guard let session = arguments["sessionId"] as? String else {
                return .failure(MCPBridgeError("snitt_screenshot requires sessionId"))
            }
            let inlineFlag: Bool
            switch booleanValue(arguments["inline"], parameter: "inline") {
            case .success(let value): inlineFlag = value ?? false
            case .failure(let error): return .failure(error)
            }
            return .success(.screenshot(sessionID: session,
                                        label: arguments["label"] as? String,
                                        inline: inlineFlag))

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
            // `booleanValue`, not `as? Bool == true`: a JSON string "true"
            // decodes to NSString, fails the cast, and falls through to the
            // rect branch. With x/y/width/height also present that is a silent
            // SUCCESS that APPLIES a crop when the caller asked to remove one,
            // the same failure shape `autoTrim` had.
            switch booleanValue(arguments["reset"], parameter: "reset") {
            case .failure(let error): return .failure(error)
            case .success(let value):
                if value == true { return .success(.crop(bundlePath: path, rect: nil)) }
            }
            let cropFrame: CoordinateFrame?
            switch frameSize(arguments, tool: "snitt_crop") {
            case .failure(let error): return .failure(error)
            case .success(let value): cropFrame = value
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
                            "snitt_crop needs x, y, width and height together: "
                          + "pixels if you also give frameWidth and frameHeight, "
                          + "otherwise fractions of the frame (0-1). Or reset: true."))
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
            return CoordinateFrame.unitRect(x: rect["x"]!, y: rect["y"]!,
                                            width: rect["width"]!, height: rect["height"]!,
                                            in: cropFrame, verb: "snitt_crop")
                .map { .crop(bundlePath: path, rect: $0) }
                .mapError { MCPBridgeError($0.message) }

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
            // On unless refused, which is the whole of PR I: the server's own
            // instructions call tidying up ONE step, and it used to cost
            // `snitt_trim` plus this, with two unrelated parameter
            // vocabularies, on every recording. Set explicitly rather than
            // left to `DeepTrimCriteria`'s own default, so the value that
            // travels says what was meant and the editor's deep trim, which
            // has a timeline and trim handles, keeps meaning what it meant.
            switch booleanValue(arguments["trimBookends"], parameter: "trimBookends") {
            case .failure(let error): return .failure(error)
            case .success(let value): criteria.trimBookends = value ?? true
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

        case "snitt_estimate":
            guard let path = arguments["bundlePath"] as? String else {
                return .failure(MCPBridgeError("snitt_estimate requires bundlePath"))
            }
            let estimateScale: Double
            switch numericValue(arguments["scale"], parameter: "scale") {
            case .failure(let error): return .failure(error)
            case .success(let value):
                estimateScale = value ?? 1.0
                guard estimateScale > 0 else {
                    return .failure(MCPBridgeError(
                        "snitt_estimate scale must be greater than 0"))
                }
            }
            // The format was hardcoded and the parameter undeclared, so
            // `{"format": "gif"}` came back as an mp4 estimate with no
            // indication it had answered a different question, the §8 shape,
            // and the CLI already refuses it in these words. Wording kept
            // deliberately identical: a caller must not be told yes by one
            // frontend and no by the other.
            if let rawFormat = arguments["format"] {
                guard let format = rawFormat as? String, format == "mp4" else {
                    return .failure(MCPBridgeError(
                        "snitt_estimate supports format mp4 only. GIF size tracks how "
                      + "much the picture moves rather than how long it runs, so a "
                      + "sample of one says too little about the whole to be worth "
                      + "reporting."))
                }
            }
            return .success(.estimateExport(
                bundlePath: PathResolver.resolve(path, workingDirectory: workingDirectory),
                scale: estimateScale, format: "mp4"))

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
            // `booleanValue`, not `as? Bool ?? false` like the lines above:
            // a mistyped flag ("clicks": "yes") should be refused by name
            // rather than silently exporting without the thing that was asked
            // for.
            let resolutionValue: ExportResolution
            if let raw = arguments["resolution"] {
                guard let name = raw as? String,
                      let parsed = ExportResolution(rawValue: name) else {
                    return .failure(MCPBridgeError(
                        "snitt_export resolution must be one of: "
                      + ExportResolution.allCases.map(\.rawValue).joined(separator: ", ")))
                }
                resolutionValue = parsed
            } else {
                resolutionValue = .source
            }
            // D105: on unless refused. §5.6 makes rendering CAPTURED input
            // opt-in because a keystroke Snitt caught may carry a token nobody
            // meant to publish. A reported click carries nothing Snitt was not
            // handed by the caller, and only reported clicks can be drawn at
            // all, so this default cannot surface anything the caller did not
            // itself report. The loop tells an agent to report every input
            // precisely so the demo is watchable; making it ask a second time
            // is how it shipped the unwatchable one anyway.
            let clicksFlag: Bool
            switch booleanValue(arguments["clicks"], parameter: "clicks") {
            case .success(let value): clicksFlag = value ?? true
            case .failure(let error): return .failure(error)
            }
            let subtitlesFlag: Bool
            switch booleanValue(arguments["subtitles"], parameter: "subtitles") {
            case .success(let value): subtitlesFlag = value ?? false
            case .failure(let error): return .failure(error)
            }
            // These two keep the Optional `booleanValue` hands back instead of
            // collapsing it with `?? false`, which every other flag here does.
            // Absent means "the document decides", not "off": collapsing it
            // would make an agent's export silently drop captions a person had
            // already turned on in the editor (D107).
            let captionsFlag: Bool?
            switch booleanValue(arguments["captions"], parameter: "captions") {
            case .success(let value): captionsFlag = value
            case .failure(let error): return .failure(error)
            }
            let markerBannersFlag: Bool?
            switch booleanValue(arguments["markerBanners"], parameter: "markerBanners") {
            case .success(let value): markerBannersFlag = value
            case .failure(let error): return .failure(error)
            }
            return .success(.export(bundlePath: PathResolver.resolve(path, workingDirectory: workingDirectory),
                                     format: format,
                                     outputPath: PathResolver.resolve(outputPath, workingDirectory: workingDirectory),
                                     scale: scale, chapters: chapters,
                                     subtitles: subtitlesFlag,
                                     maxSizeBytes: maxSizeBytes,
                                    resolution: resolutionValue,
                                    clicks: clicksFlag,
                                    captions: captionsFlag,
                                    markerBanners: markerBannersFlag))

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

    /// Reads the optional `frameWidth`/`frameHeight` pair that tells this
    /// bridge the caller's coordinates are PIXELS, and names the picture they
    /// were measured in (D105, `CoordinateFrame`).
    ///
    /// Returns nil when neither key is present, which keeps every existing
    /// fraction-shaped call meaning precisely what it meant. Half a pair is
    /// refused rather than guessed: one axis cannot say what the other's unit
    /// is, and defaulting the missing one to the other would crop, or place a
    /// click, somewhere nobody asked for.
    private static func frameSize(_ arguments: [String: Any], tool: String)
        -> Result<CoordinateFrame?, MCPBridgeError> {
        var given: [String: Double] = [:]
        for key in ["frameWidth", "frameHeight"] {
            switch numericValue(arguments[key], parameter: key) {
            case .failure(let error): return .failure(error)
            case .success(let value): if let value { given[key] = value }
            }
        }
        if given.isEmpty { return .success(nil) }
        guard let width = given["frameWidth"], let height = given["frameHeight"] else {
            return .failure(MCPBridgeError(
                "\(tool) needs frameWidth and frameHeight together. One on its own "
              + "cannot say whether the other axis is pixels or a fraction."))
        }
        return CoordinateFrame.make(width: width, height: height, verb: tool)
            .map { Optional($0) }
            .mapError { MCPBridgeError($0.message) }
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
