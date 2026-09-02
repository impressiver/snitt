// Manual verification harness for M1. Replaced by the real app at M2.
//
// This tool exists to debug permission-gated capture, so it must never die
// with a bare Swift runtime trap — an uncaught `try` at top level produces
// EXC_BREAKPOINT and tells the operator nothing about what failed.
import Foundation
import ScreenCaptureKit
import SnittCapture
import SnittDocument

/// Mic capture is opt-in. See the CaptureOptions call below for why.
let wantsMic = CommandLine.arguments.contains("--mic")

func fail(_ message: String, hint: String? = nil) -> Never {
    FileHandle.standardError.write(Data("\nERROR: \(message)\n".utf8))
    if let hint {
        FileHandle.standardError.write(Data("HINT:  \(hint)\n".utf8))
    }
    exit(1)
}

// Screen Recording must be granted before SCShareableContent will return
// anything. Preflight only reads the current state; Request is what prompts.
if !CGPreflightScreenCaptureAccess() {
    print("Screen Recording permission not granted. Requesting…")
    let granted = CGRequestScreenCaptureAccess()
    print("Request returned: \(granted)")
    if !granted {
        fail("Screen Recording permission was not granted.",
             hint: "Enable Snitt in System Settings → Privacy & Security → "
                 + "Screen & System Audio Recording, then run this again. "
                 + "macOS usually requires the app to be relaunched after "
                 + "the grant is toggled.")
    }
}

let targets: [CaptureTarget]
do {
    targets = try await CaptureTarget.available()
} catch {
    fail("Could not enumerate capture targets: \(error)",
         hint: "This almost always means Screen Recording is still denied.")
}

guard let display = targets.first(where: {
    if case .display = $0 { return true } else { return false }
}) else {
    fail("No display available to record.",
         hint: "\(targets.count) target(s) were returned, none of them a display.")
}

print("Recording display: \(display.descriptor.width)x\(display.descriptor.height)")
print(wantsMic
      ? "Microphone: ON (--mic) — expect a second permission prompt"
      : "Microphone: off (pass --mic to enable; costs an extra permission prompt)")

let output = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(
        "Desktop/SnittProbe-\(Int(Date().timeIntervalSince1970)).snitt"
    )

let recorder: Recorder
do {
    recorder = try Recorder(
        target: display,
        bundleURL: output,
        // Mic is OFF by default, deliberately. Screen + system audio cost ONE
        // permission dialog on macOS 15 (they share the "Screen & System Audio
        // Recording" grant); enabling the mic adds a SECOND, separate prompt.
        // Asking for both up front is the difference between one dialog and
        // two on a user's very first run — see spec 4.10. Pass --mic to opt in.
        options: CaptureOptions(captureMicrophone: wantsMic, captureSystemAudio: true)
    )
} catch {
    fail("Could not create the recording bundle at \(output.path): \(error)",
         hint: "The parent directory must already exist and be writable.")
}

print("Recording 5 seconds to \(output.path)")

do {
    try await recorder.start()
} catch {
    fail("Could not start capture: \(error)",
         hint: "If this mentions microphone access, grant it in System Settings "
             + "→ Privacy & Security → Microphone and run again.")
}

try? await Task.sleep(for: .seconds(5))

do {
    let bundle = try await recorder.stop()
    let meta = try RecordingMetadata.read(from: bundle)
    print("Done. Duration: \(meta.durationSeconds ?? 0)s")
    print("Bundle: \(bundle.url.path)")
} catch {
    fail("Recording failed during finalization: \(error)",
         hint: "The bundle directory may still exist at \(output.path) with "
             + "sidecar files written; capture.mov is the part to inspect.")
}
