// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AVFoundation
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
    /// Transcribes the bundle's microphone track. Nil when there is no mic
    /// track — a normal recording, not an error.
    ///
    /// Runs one recognition PER UTTERANCE, not one for the whole file.
    /// `SFSpeechRecognizer` segments file audio at silence and its single
    /// `isFinal` result carries only the LAST utterance: transcribing this
    /// recording whole returned its final 9 seconds and silently dropped the
    /// first 11. Partial results carry the running text but report every
    /// timestamp as 0, so accumulating them is not an option when word timings
    /// are the point (D62). `SpeechChunker` cuts at the same pauses the
    /// recognizer would, and each chunk's words are shifted back onto the
    /// recording's own clock.
    ///
    /// D68 measured 0.05× realtime for one pass, so paying it per chunk is
    /// still far cheaper than the capture it describes.
    static func transcribe(bundle: SnittBundle,
                           locale: Locale = Locale(identifier: "en-US"),
                           vocabulary: [String]? = nil) async throws -> Transcript? {
        let terms = resolveVocabulary(override: vocabulary, bundle: bundle)
        guard let audioURL = try await MicrophoneTrackExtractor.extract(from: bundle) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return nil }

        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration).seconds
        let samplesPerSecond = 50.0
        let peaks = try await WaveformSampler
            .sample(movieAt: audioURL, samplesPerSecond: samplesPerSecond)
            .first?.peaks ?? []
        let chunks = SpeechChunker.chunkRanges(peaks: peaks,
                                               samplesPerSecond: samplesPerSecond,
                                               duration: duration)

        var words: [TranscriptWord] = []
        for chunk in chunks {
            guard let piece = try? await exportSlice(of: asset, range: chunk) else { continue }
            defer { try? FileManager.default.removeItem(at: piece) }
            // One bad chunk must not lose the whole transcript: a recognizer
            // error on one utterance leaves the others intact, which is the
            // difference between a gap and a blank pane.
            guard let recognized = try? await recognizeOneUtterance(at: piece,
                                                                    recognizer: recognizer,
                                                                    vocabulary: terms)
            else { continue }
            // Back onto the recording's clock — the chunk reports its own.
            words.append(contentsOf: recognized.map { word in
                var moved = word
                moved.start += chunk.start
                return moved
            })
        }
        return Transcript(words: words.sorted { $0.start < $1.start },
                          locale: locale.identifier)
    }

    /// One chunk of audio as its own file, for `SFSpeechURLRecognitionRequest`.
    private static func exportSlice(of asset: AVAsset, range: TimeRange) async throws -> URL? {
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let scale = CMTimeScale(600)
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: range.start, preferredTimescale: scale),
            duration: CMTime(seconds: range.end - range.start, preferredTimescale: scale))
        let out = FileManager.default.temporaryDirectory
            .appending(path: "snitt-utterance-\(UUID().uuidString).m4a")
        try await session.export(to: out, as: .m4a)
        return out
    }

    /// Which terms this transcription should bias toward.
    ///
    /// From the RECORDING unless the caller overrides, so re-transcribing an
    /// old bundle uses the hints it was made with rather than none — which is
    /// exactly when they matter, since a re-transcription usually happens
    /// BECAUSE the first one got the names wrong.
    ///
    /// A separate function so it can be exercised without the recogniser, which
    /// is TCC-gated and absent on any machine that has not granted it.
    static func resolveVocabulary(override: [String]?, bundle: SnittBundle) -> [String] {
        let stored = (try? RecordingMetadata.read(from: bundle))?.vocabulary
        return Vocabulary.prepare(override ?? stored ?? []).terms
    }

    /// Recognizes a single-utterance file. Timestamps are relative to it.
    private static func recognizeOneUtterance(
        at url: URL, recognizer: SFSpeechRecognizer,
        vocabulary: [String] = []) async throws -> [TranscriptWord] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        // D81. Biases toward these without restricting to them, so a term that
        // is never said costs nothing — which is why an over-broad list is not
        // the failure mode and an unbounded one is (`Vocabulary.limit`).
        //
        // Set per utterance rather than once, because each chunk gets its own
        // request: `SpeechChunker` splits at silence and every piece is
        // recognised separately, so a hint applied to the first only would
        // help the first sentence and no other.
        if !vocabulary.isEmpty { request.contextualStrings = vocabulary }
        // Still false: within ONE utterance the final result is the complete
        // one, and it is the only result carrying timestamps at all.
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
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
    }
}
