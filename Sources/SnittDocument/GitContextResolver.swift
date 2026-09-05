import Foundation

/// Runs a command and returns its trimmed stdout, or nil if it failed.
///
/// Injected rather than called directly so the parsing — which is where the
/// interesting cases live — can be tested without a repository on disk.
public struct CommandRunner: Sendable {
    private let run: @Sendable (String, [String], URL) -> String?

    public init(run: @Sendable @escaping (String, [String], URL) -> String?) {
        self.run = run
    }

    public func callAsFunction(_ tool: String, _ arguments: [String],
                               in directory: URL) -> String? {
        run(tool, arguments, directory)
    }

    public static let git = CommandRunner { tool, arguments, directory in
        let process = Process()
        // `Snitt.app`'s only production caller of this resolver runs with the
        // minimal PATH LaunchServices gives a launched .app — no Homebrew, no
        // shell profile (`launchctl getenv PATH` is empty in that context).
        // `/usr/bin/env git` would resolve through that empty PATH and fail
        // silently, which means every bundle would have no git context in
        // exactly the configuration Snitt ships in. `/usr/bin/git` is Apple's
        // Git and always present on macOS, so it is tried first; falling back
        // to `env` only if that path is somehow missing keeps this working in
        // non-standard environments (e.g. tests that swap `tool`).
        let directPath = "/usr/bin/\(tool)"
        if FileManager.default.isExecutableFile(atPath: directPath) {
            process.executableURL = URL(fileURLWithPath: directPath)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [tool] + arguments
        }
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Discovers the git branch and commit a recording was made against (§7).
public enum GitContextResolver {
    public static func resolve(in directory: URL,
                               runner: CommandRunner = .git) -> GitContext? {
        func value(_ arguments: [String]) -> String? {
            guard let raw = runner("git", arguments, in: directory) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        let rawBranch = value(["rev-parse", "--abbrev-ref", "HEAD"])
        // git prints the literal "HEAD" when detached. Recording that as a
        // branch name would put a lie in every bundle made during a bisect or
        // a CI checkout, so it is dropped rather than stored.
        let branch = rawBranch == "HEAD" ? nil : rawBranch
        let commit = value(["rev-parse", "--short", "HEAD"])

        guard branch != nil || commit != nil else { return nil }
        return GitContext(branch: branch, commit: commit)
    }
}
