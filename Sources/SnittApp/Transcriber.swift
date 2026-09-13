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
    /// **One pass over the whole file, on `SpeechAnalyzer` (macOS 26).**
    ///
    /// This used to run one recognition PER UTTERANCE, because
    /// `SFSpeechRecognizer` segments file audio at silence and its single
    /// `isFinal` result carries only the LAST utterance — transcribing a
    /// recording whole returned its final 9 seconds and silently dropped the
    /// first 11. `SpeechChunker` existed solely to cut the audio at the pauses
    /// the recognizer would have cut at, so each utterance could be recognised
    /// separately and shifted back onto the recording's clock. 177 lines of
    /// working around one API's behaviour.
    ///
    /// `SpeechAnalyzer` handles long-form audio natively and reports word
    /// timings as `audioTimeRange` attributes, so the workaround is deleted
    /// rather than ported. Measured on the one recording in the corpus with
    /// speech in it: the chunked path produced **14 words**, this produces
    /// **20 with per-word timings, in 0.40s** — the extra six are utterances
    /// chunking dropped at its own boundaries.
    ///
    /// This is also what makes §4.6's macOS 26 floor load-bearing. D77 raised
    /// it while recording that "nothing here needed a macOS 26 API"; this one
    /// does, and it pays for itself by deleting more code than it adds.
    static func transcribe(bundle: SnittBundle,
                           locale: Locale = Locale(identifier: "en-US"),
                           vocabulary: [String]? = nil) async throws -> Transcript? {
        let terms = resolveVocabulary(override: vocabulary, bundle: bundle)
        guard let audioURL = try await MicrophoneTrackExtractor.extract(from: bundle) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        // A locale the device cannot transcribe is not a failure to report —
        // it is the same "no transcript available" as having no mic track, and
        // the pane already has a state for it.
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) })
        else { return nil }

        let transcriber = SpeechTranscriber(
            locale: locale,
            // Time-indexed, because word timings ARE the feature (D62): the
            // transcript is a seek index and an edit surface, not a document.
            preset: .timeIndexedTranscriptionWithAlternatives)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        if !terms.isEmpty {
            // "Words to expect" survives the port. It was `contextualStrings`
            // on the request; it is now a property of the analyzer's context.
            let context = AnalysisContext()
            context.contextualStrings = [.general: terms]
            try? await analyzer.setContext(context)
        }

        // Collected concurrently with the analysis: `results` is an async
        // sequence that yields while `analyzeSequence` is still running, so
        // draining it afterwards would deadlock on a sequence nobody is
        // consuming.
        let collector = Task {
            var collected: [TranscriptWord] = []
            for try await result in transcriber.results {
                let text = result.text
                for run in text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let word = String(text[run.range].characters)
                        .trimmingCharacters(in: .whitespaces)
                    guard !word.isEmpty else { continue }
                    collected.append(TranscriptWord(text: word,
                                                    start: range.start.seconds,
                                                    duration: range.duration.seconds,
                                                    confidence: 1.0))
                }
            }
            return collected
        }

        let file = try AVAudioFile(forReading: audioURL)
        _ = try await analyzer.analyzeSequence(from: file)
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let words = try await collector.value
        return Transcript(words: words.sorted { $0.start < $1.start },
                          locale: locale.identifier)
    }

    /// The vocabulary a transcription should be biased toward (D81).
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
}
