// S6 — Is on-device transcription good enough, and does it expose word-level
// timings? (§14, D62, D66)
//
// Throwaway, per §14. Output is a written recommendation; this code exists to
// produce the numbers that recommendation rests on.
//
// THE LOAD-BEARING QUESTION IS #2. Captions need only segment timings, but
// D62's real prize — deleting a phrase in the transcript and having it become a
// `Cut` over that span — needs WORD timings. If they are not exposed, D62
// collapses to captions and the editing half dies, and that changes what gets
// built rather than when.
//
// Run:  swift run S6TranscriptionProbe [path/to/audio.aiff ...]
// With no arguments it generates its own speech with `say`, so the probe is
// self-contained and needs no recording to exist.
import AVFoundation
import Foundation
import Speech

let sentences = [
    "Here is the settings window I just built.",
    "Clicking save writes the value to disk and the label updates immediately.",
    "That is the whole feature, end to end.",
]

func generateSpeech() throws -> [URL] {
    var urls: [URL] = []
    for (index, sentence) in sentences.enumerated() {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "s6-sample-\(index).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, "--data-format=LEF32@22050", sentence]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            print("  ! say failed for: \(sentence)")
            continue
        }
        urls.append(url)
    }
    return urls
}

/// Extracts one audio track from a recording into a standalone file.
///
/// Necessary, not convenience: `capture.mov` carries TWO audio tracks, and
/// `AssetWriterSink` writes them in the order [systemAudio, microphone]. A
/// recogniser handed the movie takes the first track it finds — which for a
/// screen recording with no system audio is pure silence, and would report a
/// confident empty transcript. Getting that answer would be worse than getting
/// none, because it looks like a verdict on the API.
func extractAudioTrack(from movie: URL, trackIndex: Int) async throws -> URL? {
    let asset = AVURLAsset(url: movie)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    guard trackIndex < tracks.count else { return nil }
    let composition = AVMutableComposition()
    guard let destination = composition.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
    let duration = try await asset.load(.duration)
    try destination.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                    of: tracks[trackIndex], at: .zero)

    let out = FileManager.default.temporaryDirectory
        .appending(path: "s6-track\(trackIndex).m4a")
    try? FileManager.default.removeItem(at: out)
    guard let session = AVAssetExportSession(
        asset: composition, presetName: AVAssetExportPresetAppleM4A) else { return nil }
    session.outputURL = out
    session.outputFileType = .m4a
    try await session.export(to: out, as: .m4a)
    return out
}

func authorize() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
}

/// The transcript, flattened out of `SFSpeechRecognitionResult` inside the
/// callback.
///
/// `SFSpeechRecognitionResult` is not `Sendable`, so it cannot cross the
/// continuation. Copying out the three things this probe reports — text,
/// per-segment timings, confidence — keeps the concurrency checker satisfied
/// without weakening it, and is the whole answer S6 needs anyway.
struct ProbeTranscript {
    struct Segment { let text: String; let timestamp: Double; let duration: Double; let confidence: Float }
    let text: String
    let segments: [Segment]
}

func transcribe(_ url: URL, recognizer: SFSpeechRecognizer) async -> ProbeTranscript? {
    let request = SFSpeechURLRecognitionRequest(url: url)
    // The whole point: never leave the machine (D62, §3, §5).
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = false
    return await withCheckedContinuation { continuation in
        nonisolated(unsafe) var resumed = false
        recognizer.recognitionTask(with: request) { result, error in
            guard !resumed else { return }
            if let error {
                print("  ! recognition error: \(error.localizedDescription)")
                resumed = true; continuation.resume(returning: nil); return
            }
            guard let result, result.isFinal else { return }
            resumed = true
            let transcript = result.bestTranscription
            continuation.resume(returning: ProbeTranscript(
                text: transcript.formattedString,
                segments: transcript.segments.map {
                    ProbeTranscript.Segment(text: $0.substring, timestamp: $0.timestamp,
                                            duration: $0.duration, confidence: $0.confidence)
                }))
        }
    }
}

// MARK: - Run

// Line-buffered: this probe blocks on a TCC prompt, and with piped stdout
// block-buffered you see nothing at all while it waits — which reads as a hang
// rather than as "answer the dialog". Found by running it exactly that way.
setvbuf(stdout, nil, _IOLBF, 0)

print("S6 — on-device transcription probe")
print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n")

guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
    print("FAIL: no recognizer for en-US")
    exit(1)
}

print("Q1. Availability at this OS")
print("  recognizer.isAvailable:              \(recognizer.isAvailable)")
print("  supportsOnDeviceRecognition:         \(recognizer.supportsOnDeviceRecognition)")
if !recognizer.supportsOnDeviceRecognition {
    print("  → D62 says the feature WAITS rather than going to a server. Stop here.")
}

print("\n  Requesting Speech Recognition authorization — macOS will prompt.")
print("  (A CLI's grant is attributed to the TERMINAL that launched it, not to")
print("   Snitt.app, which is the same attribution problem §4.9 describes for")
print("   screen recording. Granting here does not grant it to the app.)")
let status = await authorize()
print("  authorization:                       \(status)")
guard status == .authorized else {
    print("""

      Not authorized. Speech recognition is TCC-gated, and a CLI's grant is
      attributed to the terminal that launched it — the same attribution problem
      §4.9 describes for screen recording. That is itself a finding: the real
      app will need its own NSSpeechRecognitionUsageDescription and its own
      prompt, and this probe cannot stand in for that.
    """)
    exit(2)
}

var inputs: [URL] = []
if CommandLine.arguments.count > 1 {
    for argument in CommandLine.arguments.dropFirst() {
        var url = URL(fileURLWithPath: argument)
        // A .snitt bundle: reach inside for the movie.
        if url.pathExtension == "snitt" { url = url.appending(path: "capture.mov") }
        if url.pathExtension == "mov" {
            print("  extracting the microphone track from \(url.lastPathComponent)")
            // Index 1 = microphone, per AudioTrackOrder.canonical.
            guard let mic = try await extractAudioTrack(from: url, trackIndex: 1) else {
                print("  ! no microphone track in \(url.lastPathComponent) — was the mic on?")
                continue
            }
            inputs.append(mic)
        } else {
            inputs.append(url)
        }
    }
} else {
    print("\n  (no audio given — generating speech with `say`)")
    inputs = (try? generateSpeech()) ?? []
}
guard !inputs.isEmpty else { print("no audio to transcribe"); exit(1) }

var sawWordTimings = false
for url in inputs {
    let duration = try? await AVURLAsset(url: url).load(.duration).seconds
    print("\n── \(url.lastPathComponent) (\(String(format: "%.1f", duration ?? 0))s audio)")

    let started = Date()
    guard let result = await transcribe(url, recognizer: recognizer) else { continue }
    let elapsed = Date().timeIntervalSince(started)

    print("  text: \(result.text)")

    print("\nQ3. Cost")
    print("  wall-clock: \(String(format: "%.2f", elapsed))s for \(String(format: "%.1f", duration ?? 0))s of audio")
    print("  ratio:      \(String(format: "%.2fx", elapsed / max(0.001, duration ?? 1))) realtime")

    print("\nQ2. Word-level timings — THE decisive question")
    let segments = result.segments
    print("  segments: \(segments.count)")
    for segment in segments.prefix(6) {
        print(String(format: "    %-18@ t=%.2fs  dur=%.2fs  conf=%.2f",
                     segment.text as NSString, segment.timestamp,
                     segment.duration, segment.confidence))
    }
    // A segment per WORD with distinct, increasing timestamps is what D62's
    // text-based editing needs. One segment for the whole utterance, or
    // timestamps that are all zero, means captions only.
    let distinct = Set(segments.map { $0.timestamp }).count
    let looksWordLevel = segments.count > 2 && distinct == segments.count
        && segments.contains { $0.duration > 0 }
    print("  → \(looksWordLevel ? "WORD-LEVEL timings present" : "NOT word-level — captions only")")
    sawWordTimings = sawWordTimings || looksWordLevel
}

print("""

── Recommendation input ──────────────────────────────────────────────
Word-level timings: \(sawWordTimings ? "AVAILABLE" : "NOT AVAILABLE")

If AVAILABLE, D62's text-based editing is buildable at the macOS 15 floor and
no §4.6 change is needed. If NOT, either the floor moves (a real cost — §4.6
was chosen to delete a whole spike) or D62 ships as captions only and the
editing half is dropped from the pillar D66 names.
""")
