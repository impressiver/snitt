// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

// snitt-mcp — an MCP server over stdio.
//
// JSON-RPC 2.0, one message per line. Every tool maps to the same request the
// CLI builds and travels through the same client, so the two frontends cannot
// diverge (spec §4.8). This process never touches ScreenCaptureKit: macOS
// attributes a capture grant to the responsible process, and Snitt.app holds
// it — this only asks it to act (§4.9).
import Foundation
import SnittAutomation
import SnittDocument

func respond(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

func result(id: Any?, _ payload: [String: Any]) {
    respond(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": payload])
}

func failure(id: Any?, _ message: String) {
    respond(["jsonrpc": "2.0", "id": id ?? NSNull(),
             "error": ["code": -32000, "message": message]])
}

func textContent(_ text: String) -> [String: Any] {
    ["content": [["type": "text", "text": text]]]
}

/// A tool result carrying BOTH halves: the prose a person reads in a log, and
/// the object an agent parses. The text block stays exactly as it was, so
/// nothing that reads the prose today breaks.
func toolResult(_ text: String, structured: [String: Any]?) -> [String: Any] {
    var payload = textContent(text)
    if let structured { payload["structuredContent"] = structured }
    return payload
}

/// A tool result that also carries the frame itself.
///
/// The image is a SECOND content block beside the text, which is how MCP
/// carries pixels: a host that renders images shows it, and one that does not
/// still has the sentence and the path. Only `snitt_screenshot` produces this,
/// and only when the caller passed `inline`.
func toolResultWithImage(_ text: String, structured: [String: Any]?,
                         png: Data) -> [String: Any] {
    var payload = toolResult(text, structured: structured)
    var blocks = (payload["content"] as? [[String: Any]]) ?? []
    blocks.append(["type": "image",
                   "data": png.base64EncodedString(),
                   "mimeType": "image/png"])
    payload["content"] = blocks
    return payload
}

/// A tool CALL that fails — bad arguments, an unknown tool name, or a request
/// the app itself refused — is reported through the result channel with
/// `isError: true`, not as a JSON-RPC protocol error. A protocol error means
/// "the request itself was malformed" and a real client may treat it as fatal
/// for the call; a well-formed call that then fails is tool output, and the
/// calling model needs to see that text to self-correct (e.g. add the missing
/// argument and retry). Genuine protocol errors stay for what they mean: an
/// unsupported method, or a message that cannot be parsed as JSON-RPC at all.
func toolError(id: Any?, _ text: String, structured: [String: Any]? = nil) {
    result(id: id, toolErrorPayload(text, structured: structured))
}

/// The dictionary `toolError` sends, separated so a test can read it: the
/// writing half goes to stdout and cannot be asserted on.
///
/// `isError` is set on top of an ordinary tool result rather than beside a
/// hand-built one, so a failed call carries `structuredContent` for the same
/// reason a successful call does (D103, D106): the calling model is expected
/// to self-correct from this, and it can only do that from the code.
func toolErrorPayload(_ text: String, structured: [String: Any]?) -> [String: Any] {
    var payload = toolResult(text, structured: structured)
    payload["isError"] = true
    return payload
}

/// Renders a refused tool call (bad arguments, an unknown tool name) the way
/// a refusal from the app itself is rendered (D106).
///
/// The point is the shared path, not the wrapping. `MCPBridgeError` becomes an
/// `AutomationError` and then travels through the SAME `describe` and
/// `structuredContent` every app-side `.failure` travels through, so an agent
/// reads one error shape from this server rather than two: a code-prefixed
/// sentence plus a `{code, message}` object it can branch on. Before this it
/// got bare prose and `isError: true`, with nothing machine-readable at all:
/// the state `AutomationError.Code`'s "an agent branches on this, never on
/// `message`" contract was written to prevent and never reached.
///
/// A named function rather than an inline expression at the call site, so a
/// test can exercise it without driving the JSON-RPC loop, the same reason
/// `exportSummary` and `diagnosticsSummary` are separate.
func argumentFailure(_ problem: MCPBridgeError) -> (text: String, structured: [String: Any]?) {
    let response = AutomationResponse.failure(problem.automationError)
    return (describe(response), structuredContent(response))
}

/// Renders `.exported`'s manifest as the text an agent reads back.
///
/// A separate function, not inlined into `describe`'s switch, so it can be
/// exercised directly by a test without driving the whole JSON-RPC loop —
/// and so its budget-miss wording is verifiably the same sentence `emit`'s
/// note in the CLI produces (§4.8), both built from the shared
/// `sizeBudgetNote` in `SnittAutomation`.
func exportSummary(_ manifest: ExportManifest) -> String {
    let megabytes = Double(manifest.byteSize) / 1_000_000
    let chapters = manifest.chapters.map(\.title).joined(separator: ", ")
    var text = "Exported \(Int(manifest.durationSeconds))s to \(manifest.outputPath) "
             + "(\(String(format: "%.1f", megabytes)) MB)"
    if let note = sizeBudgetNote(manifest) {
        text += " — \(note)"
    }
    text += chapters.isEmpty ? "" : ", chapters: \(chapters)"
    return text
}

/// One `Encodable` as a JSON object, for embedding in `structuredContent`.
///
/// Round-trips through `JSONSerialization` rather than being hand-built,
/// so the structured payload and the CLI's `emit` cannot drift: both are the
/// same `Codable` value, encoded the same way.
func jsonObject(_ value: some Encodable) -> [String: Any]? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// The machine-readable half of a tool result (§4.8's agent-facing contract,
/// extended to MCP by D103).
///
/// Mirrors what `snitt-cli` already writes to stdout for the same response, so
/// the two frontends answer with the same FIELDS and differ only in transport.
/// Before this existed, `describe` rendered most cases as prose and an agent
/// had to pattern-match a sentence to recover a `sessionId` or a `bundlePath` —
/// values that thirteen tool signatures require as input.
///
/// `nil` means "nothing machine-readable to add", not "failed": the prose text
/// block is always present, so a case that has no structured form simply omits
/// the key rather than shipping an empty object a client might branch on.
func structuredContent(_ response: AutomationResponse) -> [String: Any]? {
    switch response {
    case .handshake(let info):
        return jsonObject(info)
    case .targets(let targets):
        // Arrays are not valid `structuredContent`, which must be an object, so
        // the list is named rather than returned bare.
        guard let data = try? JSONEncoder().encode(targets),
              let array = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return ["targets": array]
    case .started(let id, let target, let vocabularyDropped):
        var payload: [String: Any] = ["sessionId": id, "target": target]
        // Omitted when nil, so "no vocabulary was sent" is an absent key rather
        // than a zero that would read as "all of yours were kept": the same
        // absent-means-absent rule `healthFields` enforces for `.stopped`.
        if let vocabularyDropped { payload["vocabularyDropped"] = vocabularyDropped }
        return payload
    case .stopped(let path, let health):
        var payload: [String: Any] = ["bundlePath": path]
        let block = healthFields(health)
        if !block.isEmpty { payload["health"] = block }
        return payload
    case .status(let info):
        return jsonObject(info)
    case .failure(let error):
        return jsonObject(error)
    case .marked(let timeSeconds):
        return ["markedAt": timeSeconds]
    case .inspected(let report):
        // The case this matters most for. `InspectReport` exists, in its own
        // words, "so an agent can write something factually true in a pull
        // request instead of narrating a recording it has never seen" — and
        // the prose rendering drops `health` and `git`, which are exactly the
        // fields that claim rests on.
        return jsonObject(report)
    case .trimmed(let summary):
        return jsonObject(summary)
    case .cropped(let summary):
        return jsonObject(summary)
    case .autoTrimmed(let summary):
        return jsonObject(summary)
    case .estimated(let estimates):
        guard let data = try? JSONEncoder().encode(estimates),
              let array = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return ["estimates": array]
    case .screenshotTaken(let path, let timeSeconds, _):
        // The image goes in a content BLOCK, not in here: `structuredContent`
        // is for values an agent computes with, and base64 pixels are neither
        // that nor something worth duplicating in two places in one response.
        return ["path": path, "timeSeconds": timeSeconds]
    case .exported(let manifest):
        return jsonObject(manifest)
    case .diagnosticsWritten(let report):
        return jsonObject(report)
    }
}

/// Renders a response as the text an agent reads back.
func describe(_ response: AutomationResponse) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    switch response {
    case .targets(let targets):
        return (try? encoder.encode(targets)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "[]"
    case .started(let id, let target, let vocabularyDropped):
        // The truncation warning rides on the SUCCESS, because that is what it
        // is: the recording started, and some of the terms it was given are
        // not biasing anything. Built by the shared `vocabularyNote` so this
        // sentence and the CLI's cannot drift apart (§4.8).
        let text = "Recording \(target). Session id: \(id)"
        return vocabularyNote(vocabularyDropped).map { "\(text) \($0)" } ?? text
    case .stopped(let path, let health):
        // Same "absent means absent" rendering the CLI uses (§4.8: the two
        // frontends must not diverge), via the shared `healthFields` helper.
        let fields = healthFields(health)
        guard !fields.isEmpty else { return "Saved \(path)" }
        let metrics = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        return "Saved \(path) (\(metrics))"
    case .status(let info):
        return (try? encoder.encode(info)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    case .handshake(let info):
        return "Snitt \(info.appVersion), protocol \(info.protocolVersion)"
    case .failure(let error):
        return "\(error.code.rawValue): \(error.message)" + (error.hint.map { "\n\($0)" } ?? "")
    case .marked(let timeSeconds):
        return "Marker placed at \(timeSeconds)s"
    case .inspected(let report):
        let chapters = report.markers
            .map { String(format: "%.0fs %@", $0.timeSeconds, $0.label ?? "(unlabelled)") }
            .joined(separator: ", ")
        return "\(Int(report.durationSeconds ?? 0))s recording, "
             + "\(report.markerCount) markers, \(report.inputEventCount) input events"
             + (chapters.isEmpty ? "" : " — \(chapters)")
    case .screenshotTaken(let path, let timeSeconds, _):
        // The offset is in the text, not only the filename: an agent quoting
        // the demo needs to say WHEN, and reading it back out of a path is
        // work it should not have to do.
        return String(format: "Screenshot of the recording at %.2fs, saved to %@. "
                    + "A marker was placed at the same instant.", timeSeconds, path as NSString)
    case .estimated(let estimates):
        guard let first = estimates.first else { return "No resolutions available." }
        // Every option in one answer, and the caveat stated once at the top
        // rather than implied: these are ceilings, and generous ones.
        let rows = estimates.map {
            String(format: "  %@: %dx%d, no larger than %.1fMB",
                   $0.resolution.rawValue as NSString, $0.width, $0.height,
                   Double($0.estimatedMaxBytes) / 1_000_000)
        }.joined(separator: "\n")
        return String(format: "%.1fs of footage. These are AVFoundation ceilings and run "
                            + "generous (about 4x the real file on a 5K recording) — use "
                            + "them to choose a resolution, and maxSize to fit a budget.\n%@",
                      first.durationSeconds, rows as NSString)
    case .autoTrimmed(let summary):
        // Seconds, not span boundaries: an agent cannot watch the result, and
        // what it needs to decide next is how much is left.
        return summary.spans == 0
            ? "No dead air found; the recording is unchanged."
            : String(format: "Removed %d dead span(s) totalling %.1fs. %.1fs remains, in %d cut(s).",
                     summary.spans, summary.seconds, summary.remainingSeconds, summary.totalCuts)
    case .cropped(let summary):
        // Dimensions, not fractions: an agent cannot look at the video, and
        // pixels are what it needs to reason about a --max-size budget.
        if let crop = summary.crop {
            return String(format: "Cropped to %.0f%%x%.0f%% of the frame. "
                        + "Exports at %dx%d.",
                          crop.width * 100, crop.height * 100,
                          summary.pixelWidth, summary.pixelHeight)
        }
        return "Crop removed. Exports at \(summary.pixelWidth)x\(summary.pixelHeight)."

    case .trimmed(let summary):
        // An MCP client reads text, not JSON structure — prose is the
        // deliverable, same as every other case here.
        let cuts = summary.cuts
            .map { String(format: "%.0f-%.0fs", $0.start, $0.end) }
            .joined(separator: ", ")
        return "Kept \(Int(summary.keptSeconds))s, cut \(Int(summary.cutSeconds))s"
             + (cuts.isEmpty ? "" : " (\(cuts))")
    case .exported(let manifest):
        return exportSummary(manifest)
    case .diagnosticsWritten(let report):
        // No `outputPath` here: `DiagnosticsReport` doesn't carry it. The
        // caller (`tools/call` below) renders this case itself, with the
        // path it already resolved from the tool arguments, rather than
        // going through this generic renderer.
        return diagnosticsSummary(report, outputPath: "the requested path")
    }
}

/// Renders `.diagnosticsWritten`'s report as the text an agent reads back.
///
/// A separate function, not inlined into `describe`'s switch, for the same
/// reason `exportSummary` is: it can be exercised directly by a test, and
/// its wording is verifiably the same shape the CLI's `diagnosticsNote`
/// produces (§4.8).
func diagnosticsSummary(_ report: DiagnosticsReport, outputPath: String) -> String {
    let permissions = report.permissions.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    // Crash reporting is opt-in and off by default (§12) — say which
    // happened, not just how many: "0 crash reports" reads the same whether
    // nothing crashed or nobody turned collection on.
    let crashReportsNote = report.crashReportingEnabled
        ? "\(report.crashReports.count) crash report(s)"
        : "crash reporting off"
    return "Wrote diagnostics bundle to \(outputPath): "
         + "\(report.recentSessions.count) recent session(s), "
         + "\(report.logLines.count) log line(s), "
         + "\(crashReportsNote), "
         + "app \(report.appVersion), protocol \(report.protocolVersion)"
         + (permissions.isEmpty ? "" : " — \(permissions)")
}

/// The `initialize` result. Extracted so a test can assert on it — the
/// `instructions` field is prose about a tool surface, and prose drifting from
/// the tools it names is the failure S5 names with no version handshake to
/// catch it (§10 covers the wire protocol, not the documentation).
func initializeResult() -> [String: Any] {
    ["protocolVersion": "2024-11-05",
     "capabilities": ["tools": [String: Any]()],
     "serverInfo": ["name": "snitt", "version": "0.1.0"],
     "instructions": MCPBridge.serverInstructions]
}

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }

    let id = message["id"]
    switch message["method"] as? String {
    case "initialize":
        result(id: id, initializeResult())

    case "tools/list":
        let tools: [[String: Any]] = MCPBridge.toolDefinitions().map { tool in
            ["name": tool.name,
             "description": tool.description,
             "inputSchema": tool.inputSchema]
        }
        result(id: id, ["tools": tools])

    case "tools/call":
        let params = message["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        switch MCPBridge.request(forTool: name, arguments: arguments) {
        case .failure(let problem):
            let rendered = argumentFailure(problem)
            toolError(id: id, rendered.text, structured: rendered.structured)
        case .success(let body):
            // `DiagnosticsReport` (unlike `ExportManifest`) carries no
            // `outputPath` of its own — captured here, from the SAME
            // resolved value `body` already carries, so the rendered text
            // can still say where the file went.
            var diagnosticsOutputPath: String?
            if case .diagnostics(let path) = body { diagnosticsOutputPath = path }
            do {
                // The launch is announced on stderr, which an MCP host logs:
                // starting an application on someone's machine is not something
                // a tool should do silently.
                let client = AutomationClient(onLaunch: {
                    FileHandle.standardError.write(
                        Data("snitt: started \($0.lastPathComponent)\n".utf8))
                })
                let response = try await client.send(body)
                if case .diagnosticsWritten(let report) = response, let diagnosticsOutputPath {
                    result(id: id, toolResult(
                        diagnosticsSummary(report, outputPath: diagnosticsOutputPath),
                        structured: structuredContent(response)))
                } else if case .screenshotTaken(_, _, let png) = response, let png {
                    result(id: id, toolResultWithImage(
                        describe(response),
                        structured: structuredContent(response),
                        png: png))
                } else {
                    result(id: id, toolResult(describe(response),
                                              structured: structuredContent(response)))
                }
            } catch ClientError.notRunning {
                // Fail immediately rather than block: an agent cannot see or
                // answer a dialog, and a hung call is worse than a clean error
                // (§11). Nothing is listening at all here.
                result(id: id, textContent(
                    "Snitt is not running. Ask the person at the machine to open it."))
            } catch ClientError.timedOut {
                // Snitt IS running — it accepted the connection and never
                // answered. Telling an agent to launch it would send it down
                // the wrong path entirely (task-8 ruling): distinct message.
                result(id: id, textContent(
                    "Snitt is running but did not respond in time. It may be stuck — "
                  + "ask the person at the machine to check the menu bar item, or quit "
                  + "and relaunch Snitt if this keeps happening."))
            } catch ClientError.timeoutUnavailable {
                // Refused rather than risk an unbounded call that looks
                // bounded (§11).
                result(id: id, textContent(
                    "Could not set a network timeout for the connection to Snitt, so the "
                  + "request was refused instead of possibly hanging forever. Try again; "
                  + "if it keeps happening, this points at a system-level socket problem."))
            } catch ClientError.malformedResponse {
                result(id: id, textContent(
                    "Snitt sent a response that could not be understood. This usually "
                  + "means Snitt and snitt-mcp are out of sync — try updating one or the other."))
            } catch {
                result(id: id, textContent("Could not talk to Snitt: \(error)"))
            }
        }

    default:
        if id != nil { failure(id: id, "Unsupported method") }
    }
}
