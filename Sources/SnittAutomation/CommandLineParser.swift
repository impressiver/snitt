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
    case status
    case help
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
            default:
                return .failure(ParseFailure("Unknown record subcommand: \(sub)"))
            }

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
}
