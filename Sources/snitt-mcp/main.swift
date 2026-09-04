// snitt-mcp — an MCP server over stdio.
//
// JSON-RPC 2.0, one message per line. Every tool maps to the same request the
// CLI builds and travels through the same client, so the two frontends cannot
// diverge (spec §4.8). This process never touches ScreenCaptureKit: macOS
// attributes a capture grant to the responsible process, and Snitt.app holds
// it — this only asks it to act (§4.9).
import Foundation
import SnittAutomation

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

/// A tool CALL that fails — bad arguments, an unknown tool name, or a request
/// the app itself refused — is reported through the result channel with
/// `isError: true`, not as a JSON-RPC protocol error. A protocol error means
/// "the request itself was malformed" and a real client may treat it as fatal
/// for the call; a well-formed call that then fails is tool output, and the
/// calling model needs to see that text to self-correct (e.g. add the missing
/// argument and retry). Genuine protocol errors stay for what they mean: an
/// unsupported method, or a message that cannot be parsed as JSON-RPC at all.
func toolError(id: Any?, _ text: String) {
    result(id: id, ["content": [["type": "text", "text": text]], "isError": true])
}

/// Renders a response as the text an agent reads back.
func describe(_ response: AutomationResponse) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    switch response {
    case .targets(let targets):
        return (try? encoder.encode(targets)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "[]"
    case .started(let id, let target):
        return "Recording \(target). Session id: \(id)"
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
    case .trimmed(let summary):
        // No MCP tool builds a `.trim` request yet — trim and export land on
        // the wire in this change, with their tool surface to follow. This
        // case exists so `describe` stays exhaustive.
        return (try? encoder.encode(summary)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    case .exported(let manifest):
        return (try? encoder.encode(manifest)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { continue }

    let id = message["id"]
    switch message["method"] as? String {
    case "initialize":
        result(id: id, [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "snitt", "version": "0.1.0"],
        ])

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
            toolError(id: id, problem.message)
        case .success(let body):
            do {
                let response = try await AutomationClient().send(body)
                result(id: id, textContent(describe(response)))
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
