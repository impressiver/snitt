// THROWAWAY SPIKE CODE — spec section 14, S4. Do not build on this.
//
// Question: is the macOS monthly screen-recording re-consent prompt scoped to
// the APP (any SCShareableContent use taints it) or to the recording PATH?
//
// This cannot be answered from documentation, and it cannot be answered
// quickly: the prompt is monthly. This harness records which selection path
// each recording used and when, so that when a prompt eventually fires the
// history can be correlated against it.
import Foundation
@preconcurrency import ScreenCaptureKit

@main
struct S4Probe {
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/snitt-s4-observation.log")

    static func main() async {
        let mode = CommandLine.arguments.dropFirst().first ?? "enumerate"
        switch mode {
        case "enumerate":
            await recordEnumeration()
        case "note-prompt":
            append("PROMPT-OBSERVED user reported the monthly re-consent prompt")
            print("Recorded. Include this timestamp in the findings table.")
        case "report":
            printReport()
        default:
            print("usage: S4Probe [enumerate|note-prompt|report]")
        }
    }

    /// Exercises the bypass path once and logs it.
    static func recordEnumeration() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            append("ENUMERATE ok displays=\(content.displays.count) windows=\(content.windows.count)")
            print("Logged one SCShareableContent call.")
        } catch {
            append("ENUMERATE failed \(error)")
            print("Failed: \(error)")
        }
    }

    static func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = Data("\(stamp) \(line)\n".utf8)

        // First write: the file does not exist, so creating it is safe.
        if !FileManager.default.fileExists(atPath: logURL.path) {
            do {
                try entry.write(to: logURL)
            } catch {
                FileHandle.standardError.write(
                    Data("s4: could not create log at \(logURL.path): \(error)\n".utf8))
            }
            return
        }

        // The log EXISTS. Append only. There is deliberately no whole-file-write
        // fallback here: Data.write(to:) truncates, and this log accumulates
        // months of observations that cannot be regenerated. Failing loudly and
        // losing one line beats succeeding quietly and losing everything.
        do {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: entry)
        } catch {
            FileHandle.standardError.write(
                Data("s4: could not append to log (\(error)) — log left intact\n".utf8))
        }
    }

    static func printReport() {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else {
            print("No observations yet at \(logURL.path)")
            return
        }
        print(text)
    }
}
