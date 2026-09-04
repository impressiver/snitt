import Foundation

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
    case export(bundlePath: String, format: String, outputPath: String,
                scale: Double, chapters: Bool)
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

        case "export":
            guard let path = args.first else {
                return .failure(ParseFailure(
                    "`export` needs a path to a .snitt bundle. "
                  + "Use the path `snitt record stop` printed."))
            }
            return parseExport(path: path, args: Array(args.dropFirst()))

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
                guard index < args.count, let value = Double(args[index]) else {
                    return .failure(ParseFailure("--start needs a number of seconds"))
                }
                start = value
            case "--end":
                index += 1
                guard index < args.count, let value = Double(args[index]) else {
                    return .failure(ParseFailure("--end needs a number of seconds"))
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
        return .success(.trim(bundlePath: path, start: start, end: end, auto: auto))
    }

    private static func parseExport(path: String, args: [String]) -> Result<ParsedCommand, ParseFailure> {
        var format: String?
        var outputPath: String?
        var scale = 1.0
        var chapters = false
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
                guard index < args.count, let value = Double(args[index]) else {
                    return .failure(ParseFailure("--scale needs a number"))
                }
                scale = value
            case "--chapters":
                chapters = true
            default:
                return .failure(ParseFailure("Unknown option: \(args[index])"))
            }
            index += 1
        }
        guard let format else {
            return .failure(ParseFailure("`export` needs --format mp4"))
        }
        // gif is M3d — a separate encoder entirely. Accepting it here would
        // silently write an mp4 to a path that says .gif.
        guard format == "mp4" else {
            return .failure(ParseFailure(
                "Unsupported export format: \(format). Only mp4 is supported in this "
              + "milestone; gif is planned for a later release."))
        }
        guard let outputPath else {
            return .failure(ParseFailure("`export` needs --out <path>"))
        }
        return .success(.export(bundlePath: path, format: format, outputPath: outputPath,
                                 scale: scale, chapters: chapters))
    }
}
