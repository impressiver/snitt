// Manual verification harness for M1. Replaced by the real app at M2.
import Foundation
import SnittCapture
import SnittDocument

let targets = try await CaptureTarget.available()
guard let display = targets.first(where: {
    if case .display = $0 { return true } else { return false }
}) else {
    FileHandle.standardError.write(Data("no display available\n".utf8))
    exit(1)
}

let output = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(
        "Desktop/SnittProbe-\(Int(Date().timeIntervalSince1970)).snitt"
    )

let recorder = try Recorder(
    target: display,
    bundleURL: output,
    options: CaptureOptions(captureMicrophone: true, captureSystemAudio: true)
)

print("Recording 5 seconds to \(output.path)")
try await recorder.start()
try await Task.sleep(for: .seconds(5))
let bundle = try await recorder.stop()

let meta = try RecordingMetadata.read(from: bundle)
print("Done. Duration: \(meta.durationSeconds ?? 0)s")
print("Bundle: \(bundle.url.path)")
