// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

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
        [--window-id <id>]               required if the app has >1 window
        (records the WHOLE window, tab strip included)
        [--display <id>] [--max-duration <seconds>]
        [--mic] [--no-system-audio]        record the mic; drop system audio
  snitt record stop <session-id>         stop; prints the bundle path
  snitt record mark <session-id> [--label <text>]   drop a marker
  snitt record keystroke <session>        report that you typed (no text)
  snitt record click|cursor <session> <x> <y>
                                          report input the OS never saw
  snitt record screenshot <session> [--label "..."]
                                          save the current frame, marked
  snitt record pause <session>            stop filming without ending
  snitt record resume <session>           start filming again
  snitt setup [--apply]                   register the MCP server with agents
  snitt crop <bundle> --x F --y F --width F --height F
        [--reset]                        crop, in fractions of the frame
  snitt auto-deep-trim <bundle>          cut the spans where nothing happens
        [--preset conservative|default|aggressive]
        [--min-span S] [--audio-silence F] [--frame-stillness F]
        [--input-padding S] [--reading-time S]
                                         a preset sets all five; each flag
                                          overrides one of them
  snitt estimate <bundle> [--scale F]    duration, size and an upper bound on
                                          bytes, without doing the export
  snitt inspect <bundle>                 metadata as JSON, no GUI
  snitt trim <bundle> --start <s> --end <s>   cut a range (edit.json only)
  snitt trim <bundle> --auto-trim        trim bookends from a human recording's
                                          input events; refused on recordings
                                          with none
  snitt export <bundle> --format mp4|gif --out <path>   render a movie
        [--resolution 1080p|720p|540p|480p|2160p|source]
        [--scale <factor>] [--chapters] [--subtitles] [--clicks]
        [--max-size 10MB]
                                          scale pixels; write a .vtt from markers;
                                          draw the clicks you reported; walk down
                                          quality to hit a byte budget
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
    // The same `{code, message}` object the MCP server now returns for the
    // same class of mistake (D106), so an agent parsing stdout gets one error
    // shape from both frontends instead of a code from one and a sentence from
    // the other (§4.8). Before this, stdout was empty here.
    //
    // The exit code stays 2, and is NOT `invalid_arguments`' 17: 2 means the
    // CLI refused before it built a request, which is a fact 17 cannot carry
    // because the MCP server has no exit code at all. §15 freezes these
    // numbers, so moving 2 would break every script that already branches on
    // it, to say something the JSON on stdout now says better.
    emit(AutomationError(code: .invalidArguments, message: failure.message))
    note(failure.message)
    exit(2)
}

if case .help = command {
    note(helpText)
    exit(0)
}

// `setup` never talks to Snitt.app — it registers the MCP server with the
// agent hosts on this machine — so it short-circuits before the client below
// tries to connect. Running it while Snitt is closed has to work; that is
// precisely when someone is setting things up.
if case .setup(let apply) = command {
    let mcpPath = SetupPlan.siblingMCPPath(ofExecutable: CommandLine.arguments[0])
    guard FileManager.default.isExecutableFile(atPath: mcpPath) else {
        note("""
        Could not find snitt-mcp beside this binary (looked at \(mcpPath)).

        Both ship inside Snitt.app/Contents/Helpers. If you are running a copy
        from .build, run the one in the app bundle instead — registering a
        stale server is the version mismatch the protocol handshake refuses.
        """)
        exit(1)
    }

    let steps = SetupPlan.steps(mcpPath: mcpPath,
                                installedExecutables: installedExecutables())
    emit(SetupReport(mcpPath: mcpPath, applied: apply, steps: steps))

    var ranAny = false
    for step in steps {
        if !step.isInstalled {
            note("\(step.host): not installed (\(step.executable) is not on PATH). To register later:\n  \(step.shellLine)")
            continue
        }
        guard apply else {
            note("\(step.host): would run\n  \(step.shellLine)")
            continue
        }
        note("\(step.host): registering…")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = step.command
        do {
            try process.run()
            process.waitUntilExit()
            ranAny = true
            note(process.terminationStatus == 0
                 ? "\(step.host): registered as `\(SetupPlan.serverName)`."
                 : "\(step.host): its own command exited \(process.terminationStatus). Run it by hand:\n  \(step.shellLine)")
        } catch {
            note("\(step.host): could not launch \(step.executable): \(error.localizedDescription)")
        }
    }
    if !apply {
        note("\nNothing was changed. Re-run with --apply to register.")
    } else if ranAny {
        note("\nRestart the agent host so it picks up the new server.")
    }
    exit(0)
}

/// Which host CLIs exist on this machine.
///
/// `env` rather than parsing PATH by hand, so shims and shell functions resolve
/// the same way they will when the command is actually run.
func installedExecutables() -> Set<String> {
    var found: Set<String> = []
    for name in ["claude", "cursor"] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { continue }
        process.waitUntilExit()
        if process.terminationStatus == 0 { found.insert(name) }
    }
    return found
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
    case .recordPause(let session): return .pauseRecording(sessionID: session)
    case .recordResume(let session): return .resumeRecording(sessionID: session)
    case .recordScreenshot(let session, let label):
        return .screenshot(sessionID: session, label: label)
    case .recordInput(let session, let kind, let x, let y):
        return .reportInput(sessionID: session, kind: kind, x: x, y: y, label: nil)
    case .status: return .status
    case .inspect(let path):
        return .inspect(bundlePath: PathResolver.resolve(path, workingDirectory: currentDirectory))
    case .trim(let path, let start, let end, let auto):
        return .trim(bundlePath: PathResolver.resolve(path, workingDirectory: currentDirectory),
                     start: start, end: end, auto: auto)
    case .crop(let path, let rect):
        return .crop(bundlePath: PathResolver.resolve(path, workingDirectory: currentDirectory),
                     rect: rect)
    case .estimate(let path, let scale, let format):
        return .estimateExport(
            bundlePath: PathResolver.resolve(path, workingDirectory: currentDirectory),
            scale: scale, format: format)
    case .autoDeepTrim(let path, let criteria):
        return .autoDeepTrim(
            bundlePath: PathResolver.resolve(path, workingDirectory: currentDirectory),
            criteria: criteria)
    case .setup:
        // Unreachable: `setup` exits above, before any request is built. It
        // never talks to the app, so there is no body for it — and a fatalError
        // here is louder than a `.status` fallback that would silently make
        // `snitt setup` report whether a recording is running.
        fatalError("setup is handled before the client connects")
    case .export(let path, let format, let out, let scale, let chapters, let subtitles,
                 let maxSizeBytes, let resolution, let clicks):
        return .export(bundlePath: PathResolver.resolve(path, workingDirectory: currentDirectory),
                       format: format,
                       outputPath: PathResolver.resolve(out, workingDirectory: currentDirectory),
                       scale: scale, chapters: chapters, subtitles: subtitles,
                      maxSizeBytes: maxSizeBytes, resolution: resolution, clicks: clicks)
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
    let client = AutomationClient(timeout: isExport ? 600 : 120,
                                  onLaunch: { note("Snitt was not running — started \($0.lastPathComponent).") })
    let response = try await client.send(body)
    switch response {
    case .failure(let error):
        emit(error)
        note("\(error.message)" + (error.hint.map { "\n\($0)" } ?? ""))
        exit(AutomationError.exitCode[error.code] ?? 1)
    case .targets(let targets):        emit(targets)
    case .started(let id, let target, let vocabularyDropped):
        // `emitObject`, not `emit`: the payload now mixes strings with an
        // optional number, the same reason `.stopped` below goes this way.
        var payload: [String: Any] = ["sessionId": id, "target": target]
        if let vocabularyDropped { payload["vocabularyDropped"] = vocabularyDropped }
        emitObject(payload)
        note("Recording \(target). Stop with: snitt record stop \(id)")
        if let warning = vocabularyNote(vocabularyDropped) { note(warning) }
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
    case .status(let info):
        emit(info)
        // Prose for the state change, because `snitt record pause` returns a
        // status and "{}" on stdout is not an answer to "did it pause".
        if info.recording {
            let footage = (info.elapsedSeconds ?? 0) - (info.pausedSeconds ?? 0)
            note(info.paused
                 ? "Paused. \(Int(footage))s of footage, \(Int(info.pausedSeconds ?? 0))s paused."
                 : "Recording. \(Int(footage))s of footage.")
        } else {
            note("Not recording.")
        }
        // After the state, not instead of it: what is running is the answer to
        // `snitt status`, and the grants are why the next call may not.
        if let warning = consentNote(info.consent) { note(warning) }
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
    case .screenshotTaken(let path, let timeSeconds, _):
        emitObject(["path": path, "timeSeconds": timeSeconds])
        note("Screenshot at \(String(format: "%.2f", timeSeconds))s → \(path)")
    case .cropped(let summary):
        emit(summary)
        // Pixels, not fractions: an agent cannot look at the video, and the
        // dimensions are what it needs to reason about --max-size.
        note(summary.crop == nil
             ? "Crop removed. Exports at \(summary.pixelWidth)x\(summary.pixelHeight)."
             : "Cropped. Exports at \(summary.pixelWidth)x\(summary.pixelHeight).")
    case .estimated(let estimates):
        emit(estimates)
        // A table, because the useful act is comparing. "at most" on every row
        // rather than once at the bottom: the number is a generous ceiling, and
        // a reader who skims one line should still see which way it errs.
        if let first = estimates.first {
            note(String(format: "%.1fs of footage. Estimates are AVFOUNDATION CEILINGS "
                              + "and run generous — about 4x the real file on a 5K "
                              + "recording. Use --max-size to actually fit a budget.",
                        first.durationSeconds))
        }
        for estimate in estimates {
            note(String(format: "  %-7@ %5dx%-5d at most %7.1fMB",
                        estimate.resolution.rawValue as NSString,
                        estimate.width, estimate.height,
                        Double(estimate.estimatedMaxBytes) / 1_000_000))
        }
    case .autoTrimmed(let summary):
        emit(summary)
        // "Removed nothing" is a normal outcome and has to READ as one — the
        // recording had no dead air by the criteria asked for, which is not a
        // failure and not an error to retry.
        note(summary.spans == 0
             ? "No dead air found. \(summary.totalCuts) cut(s) already in this recording."
             : String(format: "Cut %d span(s), %.1fs. %.1fs remains.",
                      summary.spans, summary.seconds, summary.remainingSeconds))
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
