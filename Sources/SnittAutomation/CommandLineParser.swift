import Foundation

// `Result<Success, Failure>` requires `Failure: Error`. The brief's tests compare
// against `Result<ParsedCommand, String>` directly, so `String` needs the
// conformance. `@retroactive` because neither `String` nor `Error` is ours.
extension String: @retroactive Error {}

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
    public static func parse(_ arguments: [String]) -> Result<ParsedCommand, String> {
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
                return .failure("Unknown targets subcommand. Try `snitt targets list`.")
            }
            return .success(.targetsList)

        case "record":
            guard let sub = args.first else {
                return .failure("Expected `record start` or `record stop`.")
            }
            args.removeFirst()
            switch sub {
            case "start": return parseStart(args)
            case "stop":
                guard let session = args.first else {
                    return .failure("`record stop` needs a session id. "
                                  + "Run `snitt status` to find it.")
                }
                return .success(.recordStop(session))
            default:
                return .failure("Unknown record subcommand: \(sub)")
            }

        default:
            return .failure("Unknown command: \(first). Try `snitt help`.")
        }
    }

    private static func parseStart(_ args: [String]) -> Result<ParsedCommand, String> {
        var options = StartOptions()
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--app":
                index += 1
                guard index < args.count else { return .failure("--app needs a bundle id") }
                options.bundleIdentifier = args[index]
            case "--display":
                index += 1
                guard index < args.count, let id = UInt32(args[index]) else {
                    return .failure("--display needs a numeric display id")
                }
                options.displayID = id
            case "--mic":
                options.microphone = true
            case "--no-system-audio":
                options.systemAudio = false
            case "--max-duration":
                index += 1
                guard index < args.count, let seconds = Double(args[index]) else {
                    return .failure("--max-duration needs a number of seconds")
                }
                options.maxDurationSeconds = seconds
            default:
                return .failure("Unknown option: \(args[index])")
            }
            index += 1
        }
        return .success(.recordStart(options))
    }
}
