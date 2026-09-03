// The `snitt` CLI: one request, one JSON document on stdout, one exit code.
//
// Deliberately thin. It never touches ScreenCaptureKit — macOS attributes a
// capture grant to the responsible process, so a CLI that captured directly
// would attribute the prompt to whatever launched it and re-prompt for every
// new parent (spec §4.9). Snitt.app holds the grant; this asks it to act.
import Foundation
import SnittAutomation
import SnittDocument

func emit(_ value: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(value),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

/// Emits a heterogeneous payload. `emit` takes an `Encodable`; the stop response
/// mixes a string path with optional numbers, so it goes through JSONSerialization.
func emitObject(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return }
    print(text)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let helpText = """
snitt — record a window and hand back a .snitt bundle

  snitt targets list                     what can be recorded, as JSON
  snitt record start --app <bundle-id>   start; prints a session id
        [--display <id>] [--max-duration <seconds>]
        [--mic] [--no-system-audio]        parsed, not yet applied (M3)
  snitt record stop <session-id>         stop; prints the bundle path
  snitt record mark <session-id> [--label <text>]   drop a marker
  snitt status                           whether a recording is running

Output is JSON on stdout and human text on stderr, so a script can parse one
and a person can read the other. Exit codes are distinct per failure.
"""

// Exit codes below 10 are CLI/transport-level; 10+ are AutomationError.exitCode,
// defined in the wire protocol shared with the app (§4.8, §11).
let parsed = CommandLineParser.parse(Array(CommandLine.arguments.dropFirst()))

let command: ParsedCommand
switch parsed {
case .success(let value): command = value
case .failure(let failure):
    note(failure.message)
    exit(2)
}

if case .help = command {
    note(helpText)
    exit(0)
}

let body: AutomationRequest.Body
switch command {
case .targetsList:              body = .listTargets
case .recordStart(var options):
    options.workingDirectory = FileManager.default.currentDirectoryPath
    body = .startRecording(options)
case .recordStop(let session):  body = .stopRecording(sessionID: session)
case .recordMark(let session, let label): body = .mark(sessionID: session, label: label)
case .status:                   body = .status
case .help:                     body = .status  // unreachable; handled above
}

do {
    let response = try await AutomationClient().send(body)
    switch response {
    case .failure(let error):
        emit(error)
        note("\(error.message)" + (error.hint.map { "\n\($0)" } ?? ""))
        exit(AutomationError.exitCode[error.code] ?? 1)
    case .targets(let targets):        emit(targets)
    case .started(let id, let target):
        emit(["sessionId": id, "target": target])
        note("Recording \(target). Stop with: snitt record stop \(id)")
    case .stopped(let path):
        var payload: [String: Any] = ["bundlePath": path]
        // `init(opening:)` throws if the bundle is not there — the health block
        // is best-effort reporting, so a failure to read it must not turn a
        // successful recording into a CLI error.
        if let bundle = try? SnittBundle(opening: URL(fileURLWithPath: path)),
           let meta = try? RecordingMetadata.read(from: bundle),
           let health = meta.health {
            var block: [String: Any] = [:]
            if let v = health.meanFrameVariance { block["meanFrameVariance"] = v }
            if let m = health.micRMS { block["micRMS"] = m }
            if let s = health.systemAudioRMS { block["systemAudioRMS"] = s }
            if !block.isEmpty { payload["health"] = block }
        }
        emitObject(payload)
        note("Saved \(path)")
    case .status(let info):            emit(info)
    case .handshake(let info):         emit(info)
    case .marked(let timeSeconds):
        emit(["markedAt": timeSeconds])
        note("Marker placed at \(timeSeconds)s")
    }
} catch ClientError.notRunning {
    note("Snitt is not running. Open Snitt and try again.")
    exit(3)
} catch ClientError.timedOut {
    // The app IS running — it accepted the connection and simply never
    // answered. Telling someone to launch it would send them down the wrong
    // path entirely (task-8 ruling). Distinct message, distinct exit code.
    note("Snitt is running but did not respond in time. It may be stuck — "
       + "check the menu bar item, or quit and relaunch Snitt if this keeps happening.")
    exit(4)
} catch ClientError.timeoutUnavailable {
    // Refused rather than risk an unbounded call that looks bounded (§11).
    note("Could not set a network timeout for the connection to Snitt, so the "
       + "request was refused instead of possibly hanging forever. Try again; "
       + "if it keeps happening, this points at a system-level socket problem.")
    exit(5)
} catch ClientError.malformedResponse {
    note("Snitt sent a response the CLI could not understand. This usually "
       + "means Snitt and this CLI are out of sync — try updating one or the other.")
    exit(6)
} catch {
    note("Could not talk to Snitt: \(error)")
    exit(1)
}
