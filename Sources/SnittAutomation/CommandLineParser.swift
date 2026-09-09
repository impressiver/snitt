// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittDocument

/// Why a command line could not be parsed.
///
/// A purpose-built type rather than `String`: `Result` constrains `Failure` to
/// `Error`, and making `String` itself conform — retroactively, in a library
/// target — leaks to every importer, turning every string in the program into
/// something throwable and colliding with any other module that does the same.
public struct ParseFailure: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public enum ParsedCommand: Equatable {
    case targetsList
    case recordStart(StartOptions)
    case recordStop(String)
    case recordMark(sessionID: String, label: String?)
    case status
    case help
    case inspect(bundlePath: String)
    case trim(bundlePath: String, start: Double?, end: Double?, auto: Bool)
    /// `rect` nil means `--reset`: remove the crop entirely.
    case crop(bundlePath: String, rect: CropRect?)
    /// D57. Carries the RESOLVED criteria: `--preset` picks a starting set and
    /// each per-criterion flag overrides one field of it, so the two forms the
    /// decision calls for are one value by the time anything acts on it.
    case autoDeepTrim(bundlePath: String, criteria: DeepTrimCriteria)
    case estimate(bundlePath: String, scale: Double, format: String)
    /// Register the bundled MCP server with the agent hosts on this machine.
    /// Prints by default; `apply` actually runs the registration commands.
    case setup(apply: Bool)
    /// M5e/D53: pause an agent's own session. A human recording is not
    /// pausable over IPC — see `RecordingCoordinator.setPausedForAgent`.
    case recordPause(sessionID: String)
    case recordResume(sessionID: String)
    case recordScreenshot(sessionID: String, label: String?)
    /// Report an input event the OS never saw. `x`/`y` are window fractions.
    /// `x`/`y` are nil for a `keystroke`, which happens at no particular place.
    case recordInput(sessionID: String, kind: String, x: Double?, y: Double?)
    case export(bundlePath: String, format: String, outputPath: String,
                scale: Double, chapters: Bool, subtitles: Bool, maxSizeBytes: Int?,
                resolution: ExportResolution, clicks: Bool)
    /// `outputPath` here is still the RAW string typed on the command line —
    /// `main.swift` resolves it against the caller's cwd before it reaches
    /// the wire, the same as `.export`'s `outputPath`/`.trim`'s
    /// `bundlePath`. Keeping resolution out of the parser is what makes it
    /// testable as pure string handling, independent of any real cwd.
    case diagnosticsExport(outputPath: String)
}

/// Parses the CLI's arguments. Pure, so the whole surface is testable without a
/// socket or a running app.
public enum CommandLineParser {
    public static func parse(_ arguments: [String]) -> Result<ParsedCommand, ParseFailure> {
        var args = arguments
        guard let first = args.first else { return .success(.help) }
        args.removeFirst()

        switch first {
        case "help", "--help", "-h":
            return .success(.help)

        case "status":
            return .success(.status)

        case "targets":
            guard args.first == "list" else {
                return .failure(ParseFailure("Unknown targets subcommand. Try `snitt targets list`."))
            }
            return .success(.targetsList)

        case "record":
            guard let sub = args.first else {
                return .failure(ParseFailure("Expected `record start` or `record stop`."))
            }
            args.removeFirst()
            switch sub {
            case "start": return parseStart(args)
            case "stop":
                guard let session = args.first else {
                    return .failure(ParseFailure("`record stop` needs a session id. "
                                  + "Run `snitt status` to find it."))
                }
                return .success(.recordStop(session))
            case "click", "cursor":
                guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
                    return .failure(ParseFailure(
                        "`record \(sub)` needs a session id and x y as fractions of the "
                      + "window, e.g. `snitt record click S1 0.5 0.32`"))
                }
                return .success(.recordInput(sessionID: args[0], kind: sub, x: x, y: y))
            case "keystroke":
                // No coordinates, and no text. Typing happens at no particular
                // place, and WHAT was typed is a claim about content Snitt
                // never saw — the restriction that makes reporting it
                // acceptable at all.
                guard let session = args.first else {
                    return .failure(ParseFailure(
                        "`record keystroke` needs a session id, e.g. "
                      + "`snitt record keystroke S1`. It takes no position and no text."))
                }
                return .success(.recordInput(sessionID: session, kind: sub, x: nil, y: nil))

            case "screenshot":
                guard let session = args.first else {
                    return .failure(ParseFailure(
                        "`record screenshot` needs a session id. Run `snitt status` to find it."))
                }
                var label: String?
                if args.count > 1 {
                    guard args[1] == "--label", args.count > 2 else {
                        return .failure(ParseFailure(
                            "`record screenshot` accepts only --label <text> after the session id."))
                    }
                    label = args[2]
                }
                return .success(.recordScreenshot(sessionID: session, label: label))

            case "pause", "resume":
                guard let session = args.first else {
                    return .failure(ParseFailure(
                        "`record \(sub)` needs a session id. Run `snitt status` to find it."))
                }
                return .success(sub == "pause"
                                ? .recordPause(sessionID: session)
                                : .recordResume(sessionID: session))

            case "mark":
                guard let session = args.first else {
                    return .failure(ParseFailure(
                        "`record mark` needs a session id. Run `snitt status` to find it."))
                }
                var label: String?
                if args.count > 1 {
                    guard args[1] == "--label", args.count > 2 else {
                        return .failure(ParseFailure("Unknown option after the session id. "
                                                   + "Use `--label <text>`."))
                    }
                    label = args[2]
                }
                return .success(.recordMark(sessionID: session, label: label))
            default:
                return .failure(ParseFailure("Unknown record subcommand: \(sub)"))
            }

        case "inspect":
            guard let path = args.first else {
                return .failure(ParseFailure(
                    "`inspect` needs a path to a .snitt bundle. "
                  + "Use the path `snitt record stop` printed."))
            }
            return .success(.inspect(bundlePath: path))

        case "trim":
            guard let path = args.first else {
                return .failure(ParseFailure(
                    "`trim` needs a path to a .snitt bundle. "
                  + "Use the path `snitt record stop` printed."))
            }
            return parseTrim(path: path, args: Array(args.dropFirst()))

        case "setup":
            var apply = false
            for flag in args {
                guard flag == "--apply" else {
                    return .failure(ParseFailure(
                        "Unknown setup option: \(flag). `snitt setup` prints what it "
                      + "would do; add --apply to run it."))
                }
                apply = true
            }
            return .success(.setup(apply: apply))

        case "crop":
            guard let path = args.first else {
                return .failure(ParseFailure(
                    "`crop` needs a path to a .snitt bundle. "
                  + "Use the path `snitt record stop` printed."))
            }
            return parseCrop(path: path, args: Array(args.dropFirst()))

        case "estimate":
            guard let path = args.first else {
                return .failure(ParseFailure(
                    "`estimate` needs a path to a .snitt bundle. "
                  + "Use the path `snitt record stop` printed."))
            }
            var estScale = 1.0
            var estFormat = "mp4"
            var estArgs = Array(args.dropFirst())
            while let flag = estArgs.first {
                estArgs.removeFirst()
                switch flag {
                case "--scale":
                    guard let raw = estArgs.first, let value = Double(raw), value > 0 else {
                        return .failure(ParseFailure("--scale needs a number greater than 0"))
                    }
                    estArgs.removeFirst()
                    estScale = value
                case "--format":
                    guard let raw = estArgs.first else {
                        return .failure(ParseFailure("--format needs a value"))
                    }
                    estArgs.removeFirst()
                    // Refused here as well as in the app, with matching wording
                    // (§8): a client should not be told yes and then no.
                    guard raw == "mp4" else {
                        return .failure(ParseFailure(
                            "estimate supports --format mp4 only. GIF size tracks how much "
                          + "the picture moves rather than how long it runs, so a sample of "
                          + "one says too little about the whole to be worth reporting."))
                    }
                    estFormat = raw
                default:
                    return .failure(ParseFailure("Unknown estimate option: \(flag)"))
                }
            }
            return .success(.estimate(bundlePath: path, scale: estScale, format: estFormat))

        case "auto-deep-trim":
            guard let path = args.first else {
                return .failure(ParseFailure(
                    "`auto-deep-trim` needs a path to a .snitt bundle. "
                  + "Use the path `snitt record stop` printed."))
            }
            return parseAutoDeepTrim(path: path, args: Array(args.dropFirst()))

        case "export":
            guard let path = args.first else {
                return .failure(ParseFailure(
                    "`export` needs a path to a .snitt bundle. "
                  + "Use the path `snitt record stop` printed."))
            }
            return parseExport(path: path, args: Array(args.dropFirst()))

        case "diagnostics":
            guard let sub = args.first else {
                return .failure(ParseFailure("Expected `diagnostics export`."))
            }
            args.removeFirst()
            guard sub == "export" else {
                return .failure(ParseFailure("Unknown diagnostics subcommand: \(sub)"))
            }
            return parseDiagnosticsExport(args)

        default:
            return .failure(ParseFailure("Unknown command: \(first). Try `snitt help`."))
        }
    }

    private static func parseStart(_ args: [String]) -> Result<ParsedCommand, ParseFailure> {
        var options = StartOptions()
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--app":
                index += 1
                guard index < args.count else { return .failure(ParseFailure("--app needs a bundle id")) }
                options.bundleIdentifier = args[index]
            case "--window-id":
                // §8 has documented this flag since the automation API was
                // specified; nothing implemented it, so `--app` alone was the
                // only way to name a window and an app with several got
                // whichever was largest.
                index += 1
                guard index < args.count, let id = UInt32(args[index]) else {
                    return .failure(ParseFailure("--window-id needs a window id from `snitt targets list`"))
                }
                options.windowID = id
            case "--display":
                index += 1
                guard index < args.count, let id = UInt32(args[index]) else {
                    return .failure(ParseFailure("--display needs a numeric display id"))
                }
                options.displayID = id
            case "--mic":
                options.microphone = true
            case "--no-system-audio":
                options.systemAudio = false
            case "--max-duration":
                index += 1
                guard index < args.count, let seconds = Double(args[index]) else {
                    return .failure(ParseFailure("--max-duration needs a number of seconds"))
                }
                options.maxDurationSeconds = seconds
            default:
                return .failure(ParseFailure("Unknown option: \(args[index])"))
            }
            index += 1
        }
        return .success(.recordStart(options))
    }

    private static func parseTrim(path: String, args: [String]) -> Result<ParsedCommand, ParseFailure> {
        var start: Double?
        var end: Double?
        var auto = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--start":
                index += 1
                // `Double.init(String)` accepts "nan" and "inf" as valid
                // finite-looking input; reject those explicitly rather than
                // let a non-finite bound reach the trim request.
                guard index < args.count, let value = Double(args[index]), value.isFinite else {
                    return .failure(ParseFailure("--start needs a finite number of seconds"))
                }
                start = value
            case "--end":
                index += 1
                guard index < args.count, let value = Double(args[index]), value.isFinite else {
                    return .failure(ParseFailure("--end needs a finite number of seconds"))
                }
                end = value
            case "--auto-trim":
                auto = true
            default:
                return .failure(ParseFailure("Unknown option: \(args[index])"))
            }
            index += 1
        }
        // A trim with neither a range nor --auto-trim would write an empty
        // edit and report success — the confidently-wrong failure §8 exists
        // to prevent. Refuse instead of silently trimming nothing.
        guard auto || start != nil || end != nil else {
            return .failure(ParseFailure(
                "`trim` needs either --start/--end or --auto-trim. "
              + "Writing no cuts would silently do nothing."))
        }
        // A backwards or empty range is meaningless; catching it here, where
        // the person can still fix their command, beats deferring to
        // whatever AVFoundation does with a degenerate composition.
        if let start, let end, start >= end {
            return .failure(ParseFailure(
                "--end (\(end)) must be after --start (\(start))"))
        }
        return .success(.trim(bundlePath: path, start: start, end: end, auto: auto))
    }

    /// `snitt crop <bundle> --x F --y F --width F --height F` | `--reset`
    ///
    /// Fractions of the frame (0-1), not pixels, because that is what
    /// `CropRect` stores and what survives a change of source resolution.
    /// Accepting pixels would mean this command has to read `capture.mov` to
    /// convert — a read §4.9 says the CLI cannot assume it is allowed to make.
    /// `auto-deep-trim <bundle> [--preset P] [per-criterion flags]`.
    ///
    /// The preset is a STARTING POINT that individual flags override, rather
    /// than an alternative to them — D57 asks for both, and making them
    /// exclusive would mean anyone wanting "aggressive but keep two seconds
    /// around clicks" has to restate all five values.
    private static func parseAutoDeepTrim(path: String, args: [String])
        -> Result<ParsedCommand, ParseFailure> {
        var criteria = DeepTrimCriteria.preset(.default)
        var remaining = args
        while let flag = remaining.first {
            remaining.removeFirst()
            if flag == "--preset" {
                guard let raw = remaining.first else {
                    return .failure(ParseFailure(
                        "--preset needs one of: "
                      + DeepTrimPreset.allCases.map(\.rawValue).joined(separator: ", ")))
                }
                remaining.removeFirst()
                guard let preset = DeepTrimPreset(rawValue: raw) else {
                    return .failure(ParseFailure(
                        "Unknown preset: \(raw). Expected one of: "
                      + DeepTrimPreset.allCases.map(\.rawValue).joined(separator: ", ")))
                }
                criteria = .preset(preset)
                continue
            }
            let known = ["--min-span", "--audio-silence", "--frame-stillness",
                         "--input-padding", "--reading-time"]
            guard known.contains(flag) else {
                return .failure(ParseFailure(
                    "Unknown auto-deep-trim option: \(flag). Expected --preset or one of: "
                  + known.joined(separator: ", ")))
            }
            guard let raw = remaining.first, let value = Double(raw), value >= 0 else {
                return .failure(ParseFailure("\(flag) needs a non-negative number."))
            }
            remaining.removeFirst()
            switch flag {
            case "--min-span": criteria.minimumSpan = value
            case "--audio-silence": criteria.audioSilenceFraction = Float(value)
            case "--frame-stillness": criteria.frameStillnessThreshold = value
            case "--input-padding": criteria.inputPadding = value
            default: criteria.subtitleReadingTime = value
            }
        }
        return .success(.autoDeepTrim(bundlePath: path, criteria: criteria))
    }

    private static func parseCrop(path: String, args: [String]) -> Result<ParsedCommand, ParseFailure> {
        var values: [String: Double] = [:]
        var reset = false
        var remaining = args
        while let flag = remaining.first {
            remaining.removeFirst()
            if flag == "--reset" { reset = true; continue }
            let names = ["--x": "x", "--y": "y", "--width": "width", "--height": "height"]
            guard let key = names[flag] else {
                return .failure(ParseFailure("Unknown crop option: \(flag)"))
            }
            guard let raw = remaining.first, let value = Double(raw) else {
                return .failure(ParseFailure("\(flag) needs a number between 0 and 1."))
            }
            remaining.removeFirst()
            values[key] = value
        }

        if reset {
            guard values.isEmpty else {
                return .failure(ParseFailure(
                    "`--reset` removes the crop, so it cannot be combined with "
                  + "--x/--y/--width/--height."))
            }
            return .success(.crop(bundlePath: path, rect: nil))
        }
        // All four required: a partial rect has no sensible default. Defaulting
        // the missing ones to 0 would silently crop to nothing, and defaulting
        // to full-frame would silently ignore what was typed.
        guard let x = values["x"], let y = values["y"],
              let width = values["width"], let height = values["height"] else {
            return .failure(ParseFailure(
                "`crop` needs --x, --y, --width and --height (fractions of the "
              + "frame, 0-1), or --reset to remove an existing crop."))
        }
        guard width > 0, height > 0 else {
            return .failure(ParseFailure(
                "--width and --height must be greater than 0. Use --reset to remove a crop."))
        }
        return .success(.crop(bundlePath: path,
                              rect: CropRect(x: x, y: y, width: width, height: height)))
    }

    private static func parseExport(path: String, args: [String]) -> Result<ParsedCommand, ParseFailure> {
        var format: String?
        var outputPath: String?
        var scale = 1.0
        var chapters = false
        var subtitles = false
        var clicks = false
        var resolution = ExportResolution.source
        var maxSizeBytes: Int?
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--format":
                index += 1
                guard index < args.count else { return .failure(ParseFailure("--format needs a value")) }
                format = args[index]
            case "--out":
                index += 1
                guard index < args.count else { return .failure(ParseFailure("--out needs a path")) }
                outputPath = args[index]
            case "--scale":
                index += 1
                guard index < args.count, let value = Double(args[index]), value.isFinite else {
                    return .failure(ParseFailure("--scale needs a finite number"))
                }
                scale = value
            case "--chapters":
                chapters = true
            case "--subtitles":
                subtitles = true
            case "--clicks":
                clicks = true
            case "--resolution":
                index += 1
                guard index < args.count else {
                    return .failure(ParseFailure("--resolution needs a value"))
                }
                // Refused by name rather than silently falling back to source:
                // an export that quietly ignored the size you asked for is the
                // failure this whole flag exists to prevent.
                guard let parsed = ExportResolution(rawValue: args[index]) else {
                    return .failure(ParseFailure(
                        "--resolution must be one of: "
                      + ExportResolution.allCases.map(\.rawValue).joined(separator: ", ")
                      + ", got \"\(args[index])\""))
                }
                resolution = parsed
            case "--max-size":
                index += 1
                guard index < args.count else { return .failure(ParseFailure("--max-size needs a value")) }
                let raw = args[index]
                // A present-but-unparseable --max-size must fail the call by
                // name, not silently become "no limit" — that would export
                // an oversized file and report success (§8).
                guard let bytes = ByteSize.parse(raw) else {
                    return .failure(ParseFailure(
                        "--max-size needs a size like 10MB, got \"\(raw)\""))
                }
                maxSizeBytes = bytes
            default:
                return .failure(ParseFailure("Unknown option: \(args[index])"))
            }
            index += 1
        }
        guard let format else {
            return .failure(ParseFailure("`export` needs --format mp4|gif"))
        }
        // Opening the gif seam must not open it to everything else.
        guard format == "mp4" || format == "gif" else {
            return .failure(ParseFailure(
                "Unsupported export format: \(format). Only mp4 and gif are supported."))
        }
        guard let outputPath else {
            return .failure(ParseFailure("`export` needs --out <path>"))
        }
        // A zero or negative scale produces a degenerate composition; refuse
        // it here rather than let AVFoundation fail (or worse, not fail)
        // further down the pipe.
        guard scale > 0 else {
            return .failure(ParseFailure("--scale must be greater than 0, got \(scale)"))
        }
        return .success(.export(bundlePath: path, format: format, outputPath: outputPath,
                                 scale: scale, chapters: chapters, subtitles: subtitles, maxSizeBytes: maxSizeBytes,
                                resolution: resolution, clicks: clicks))
    }

    private static func parseDiagnosticsExport(_ args: [String]) -> Result<ParsedCommand, ParseFailure> {
        var outputPath: String?
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--out":
                index += 1
                guard index < args.count else { return .failure(ParseFailure("--out needs a path")) }
                outputPath = args[index]
            default:
                return .failure(ParseFailure("Unknown option: \(args[index])"))
            }
            index += 1
        }
        guard let outputPath else {
            return .failure(ParseFailure("`diagnostics export` needs --out <path>"))
        }
        return .success(.diagnosticsExport(outputPath: outputPath))
    }
}
