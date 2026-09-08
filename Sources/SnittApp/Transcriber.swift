import Foundation
import Speech
import SnittDocument
import SnittExport

/// On-device speech-to-text for a recording (D62, verified viable by D68).
///
/// Thin by design: everything testable lives elsewhere — the extraction in
/// `MicrophoneTrackExtractor`, the model in `Transcript`, the editing in
/// `TranscriptEditing`. This file owns only the two things a test host cannot:
/// the TCC-gated recognizer and its authorization.
///
/// ON-DEVICE ONLY, unconditionally (D62): `requiresOnDeviceRecognition` is set
/// and there is no fallback path. Snitt records screens and microphones, and
/// shipping that audio to a hosted service would reverse §3 and §5 in the most
/// sensitive way available. If the device cannot transcribe, the feature
/// waits; it does not phone home.
enum Transcriber {
    enum Availability: Equatable {
        case available
        /// The user has not been asked yet. §4.10's ladder: ask at first USE,
        /// not at launch — a permission dialog with no visible cause is how
        /// trust erodes.
        case notYetRequested
        case denied
        /// No recognizer, or the model for this locale cannot run on device.
        case unsupported
    }

    static func availability(locale: Locale = Locale(identifier: "en-US")) -> Availability {
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.supportsOnDeviceRecognition else { return .unsupported }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .available
        case .notDetermined: return .notYetRequested
        default: return .denied
        }
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Transcribes the bundle's microphone track. Nil when there is no mic
    /// track — a normal recording, not an error.
    ///
    /// D68 measured 0.05× realtime, which is why this simply runs when asked
    /// rather than streaming during capture: a 10-minute recording costs ~30s
    /// in the background, and §12.1's contention concern does not apply after
    /// capture has ended.
    static func transcribe(bundle: SnittBundle,
                           locale: Locale = Locale(identifier: "en-US")) async throws -> Transcript? {
        guard let audioURL = try await MicrophoneTrackExtractor.extract(from: bundle) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return nil }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        let words: [TranscriptWord] = try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                resumed = true
                // Copied out inside the callback: SFSpeechRecognitionResult is
                // not Sendable — the same flattening the S6 probe needed.
                continuation.resume(returning: result.bestTranscription.segments.map {
                    TranscriptWord(text: $0.substring,
                                   start: $0.timestamp,
                                   duration: $0.duration,
                                   confidence: Double($0.confidence))
                })
            }
        }
        return Transcript(words: words, locale: locale.identifier)
    }
}
