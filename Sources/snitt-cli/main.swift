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

/// The human-readable line printed to stderr for `.exported`.
///
/// A separate, testable function for the same reason `emit(manifest)` above
/// it is not enough: `emit` prints the JSON, where `maxSizeMet: false` is
/// present and honest, but a script reading only this stderr line — the
/// text a person actually sees — got no mention of the miss at all. Built
/// from the shared `sizeBudgetNote` (`SnittAutomation`) so this and the MCP
/// frontend's `exportSummary` cannot drift apart (§4.8).
func exportNote(_ manifest: ExportManifest) -> String {
    var text = "Exported \(manifest.outputPath) (\(manifest.byteSize) bytes)"
    if let note = sizeBudgetNote(manifest) {
        text += " — \(note)"
    }
    return text
}

/// The human-readable line printed to stderr for `.diagnosticsWritten`.
///
/// A support command whose output is a bare "OK" makes a person guess
/// whether it worked; this names where the file went and roughly what is in
/// it, the same way `exportNote`/`stopped`'s note do for their own responses.
func diagnosticsNote(_ report: DiagnosticsReport, outputPath: String) -> String {
    let permissions = report.permissions.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    // Crash reporting is opt-in and off by default (§12) — this must say
    // which happened, not just how many. Otherwise "0 crash reports" reads
    // the same whether nothing crashed or nobody turned collection on.
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

let helpText = """
snitt — record a window and hand back a .snitt bundle

  snitt targets list                     what can be recorded, as JSON
  snitt record start --app <bundle-id>   start; prints a session id
        [--display <id>] [--max-duration <seconds>]
        [--mic] [--no-system-audio]        parsed, not yet applied (M3)
  snitt record stop <session-id>         stop; prints the bundle path
  snitt record mark <session-id> [--label <text>]   drop a marker
  snitt crop <bundle> --x F --y F --width F --height F
        [--reset]                        crop, in fractions of the frame
  snitt inspect <bundle>                 metadata as JSON, no GUI
  snitt trim <bundle> --start <s> --end <s>   cut a range (edit.json only)
  snitt trim <bundle> --auto-trim        trim bookends from a human recording's
                                          input events; refused on recordings
                                          with none
  snitt export <bundle> --format mp4|gif --out <path>   render a movie
        [--scale <factor>] [--chapters] [--max-size 10MB]
                                          scale pixels; write a .vtt from markers;
                                          walk down quality to hit a byte budget
                                          (gif has no audio track)
  snitt diagnostics export --out <path>  write a support bundle (logs, versions,
                                          permission states, recent sessions) as JSON
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

/// Maps a parsed command to the wire request, resolving any client-supplied
/// path against `currentDirectory` — the CALLER's working directory, never
/// the app's, which is `/` for `Snitt.app` and cannot know what a relative
/// path was relative to (M3c finding #3; `PathResolver`'s doc comment).
///
/// A separate, testable function — not inlined below — specifically so
/// "a relative path really is resolved before it reaches the wire" can be
/// asserted on the REQUEST BODY it produces, with an injected
/// `currentDirectory`, rather than only on whether parsing succeeded.
/// `CommandLineParserTests`/`SnittCLITests` exercise this; parsing alone
/// cannot catch a resolution step that silently never ran.
func requestBody(for command: ParsedCommand,
                 currentDirectory: String = FileManager.default.currentDirectoryPath) -> AutomationRequest.Body {
    switch command {
    case .targetsList: return .listTargets
    case .recordStart(var options):
        options.workingDirectory = currentDirectory
        return .startRecording(options)
    case .recordStop(let session): return .stopRecording(sessionID: session)
    case .recordMark(let session, let label): return .mark(sessionID: session, label: label)
    case .status: return .status
    case .inspect(let path):
        return .inspect(bundlePath: PathResolver.resolve(path, workingDirectory: currentDirectory))
    case .trim(let path, let start, let end, let auto):
        return .trim(bundlePath: PathResolver.resolve(path, workingDirectory: currentDirectory),
                     start: start, end: end, auto: auto)
    case .crop(let path, let rect):
        return .crop(bundlePath: PathResolver.resolve(path, workingDirectory: currentDirectory),
                     rect: rect)
    case .export(let path, let format, let out, let scale, let chapters, let maxSizeBytes):
        return .export(bundlePath: PathResolver.resolve(path, workingDirectory: currentDirectory),
                       format: format,
                       outputPath: PathResolver.resolve(out, workingDirectory: currentDirectory),
                       scale: scale, chapters: chapters, maxSizeBytes: maxSizeBytes)
    case .diagnosticsExport(let path):
        return .diagnostics(outputPath: PathResolver.resolve(path, workingDirectory: currentDirectory))
    case .help: return .status  // unreachable; handled above
    }
}

let body = requestBody(for: command)

let isExport: Bool
if case .export = command { isExport = true } else { isExport = false }

var diagnosticsOutputPath: String?
if case .diagnostics(let path) = body { diagnosticsOutputPath = path }

do {
    // Encoding takes seconds to tens of seconds and the default client
    // timeout is 120s. A job-id-and-poll protocol is complexity v0 does not
    // need; if exports ever exceed ten minutes, that is the moment to add one.
    let client = AutomationClient(timeout: isExport ? 600 : 120)
    let response = try await client.send(body)
    switch response {
    case .failure(let error):
        emit(error)
        note("\(error.message)" + (error.hint.map { "\n\($0)" } ?? ""))
        exit(AutomationError.exitCode[error.code] ?? 1)
    case .targets(let targets):        emit(targets)
    case .started(let id, let target):
        emit(["sessionId": id, "target": target])
        note("Recording \(target). Stop with: snitt record stop \(id)")
    case .stopped(let path, let health):
        // Rendered from the RESPONSE, never re-read from the bundle: the CLI
        // is a thin client (§4.9) and cannot assume it can read the app's
        // output directory — user-configurable, and at the time this was
        // found defaulting to `~/Desktop`, gated by the Files-and-Folders
        // TCC service, which made the filesystem-read version of this block
        // silently omit health on every real machine. The default has since
        // moved to `~/Documents/Snitt`, but the directory can still be
        // pointed anywhere, so this reasoning still holds.
        var payload: [String: Any] = ["bundlePath": path]
        let block = healthFields(health)
        if !block.isEmpty { payload["health"] = block }
        emitObject(payload)
        note("Saved \(path)")
    case .status(let info):            emit(info)
    case .handshake(let info):         emit(info)
    case .marked(let timeSeconds):
        emit(["markedAt": timeSeconds])
        note("Marker placed at \(timeSeconds)s")
    case .inspected(let report):
        emit(report)
        note("\(Int(report.durationSeconds ?? 0))s · \(report.markerCount) markers "
           + "· \(report.inputEventCount) input events")
    case .trimmed(let summary):
        emit(summary)
        note("Kept \(Int(summary.keptSeconds))s, cut \(Int(summary.cutSeconds))s")
    case .cropped(let summary):
        emit(summary)
        // Pixels, not fractions: an agent cannot look at the video, and the
        // dimensions are what it needs to reason about --max-size.
        note(summary.crop == nil
             ? "Crop removed. Exports at \(summary.pixelWidth)x\(summary.pixelHeight)."
             : "Cropped. Exports at \(summary.pixelWidth)x\(summary.pixelHeight).")
    case .exported(let manifest):
        emit(manifest)
        note(exportNote(manifest))
    case .diagnosticsWritten(let report):
        emit(report)
        note(diagnosticsNote(report, outputPath: diagnosticsOutputPath ?? "?"))
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
