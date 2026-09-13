// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AVFoundation
import Foundation
import Speech
@testable import SnittApp
@testable import SnittDocument

/// Transcription, end to end, against audio that really contains speech.
///
/// **This path had no test at all.** Every other transcript test starts from a
/// `Transcript` that already exists, so the step that produces one — the step
/// that was just ported from `SFSpeechRecognizer` to `SpeechAnalyzer` — was
/// covered by nothing.
///
/// The speech is SYNTHESISED rather than recorded, which is what makes this a
/// test instead of a fixture: `AVSpeechSynthesizer` writes a known phrase, so
/// the expected words are known exactly, nothing depends on a recording on
/// somebody's disk, and no personal audio enters the repository.
///
/// Skipped when Speech recognition is not authorised, since the grant is
/// per-binary TCC and a machine that has not given it cannot run this.
/// Evaluated once, outside the suite, because a `@Test` trait is a Sendable
/// closure and cannot reach main-actor state.
private let speechAuthorised = SFSpeechRecognizer.authorizationStatus() == .authorized
private let skipReason: Comment = "Speech recognition is not authorised for the test binary"

@MainActor
struct TranscriberSpeechTests {

    private static let phrase = "The quick brown fox jumps over the lazy dog"


    /// Writes `phrase` to a real audio file using the system voice.
    private func synthesise(to url: URL) async throws {
        let synth = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: Self.phrase)
        // Slower than default: the point is legible speech, and a fast voice
        // makes this test measure the recogniser's tolerance rather than the
        // pipeline it is supposed to be checking.
        utterance.rate = 0.45
        var file: AVAudioFile?
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            var finished = false
            synth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                guard pcm.frameLength > 0 else {
                    if !finished { finished = true; k.resume() }
                    return
                }
                if file == nil {
                    file = try? AVAudioFile(forWriting: url, settings: pcm.format.settings)
                }
                try? file?.write(from: pcm)
            }
        }
    }

    /// A bundle whose `capture.mov` carries speech in the MICROPHONE position.
    ///
    /// Two audio tracks, in `AudioTrackOrder.canonical` order — silent system
    /// audio first, speech second. The order is the point: `MicrophoneTrackExtractor`
    /// selects by index into that order, so a fixture with one audio track
    /// would transcribe the wrong thing and still look like it worked.
    private func bundleWithSpeech() async throws -> SnittBundle {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "speech-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)

        let speechURL = FileManager.default.temporaryDirectory
            .appending(path: "speech-\(UUID().uuidString).caf")
        try await synthesise(to: speechURL)
        defer { try? FileManager.default.removeItem(at: speechURL) }

        let speech = AVURLAsset(url: speechURL)
        let speechDuration = try await speech.load(.duration)
        let silentSource = FileManager.default.temporaryDirectory
            .appending(path: "silent-\(UUID().uuidString).mov")
        try await writeSyntheticMovie(to: silentSource,
                                      seconds: speechDuration.seconds,
                                      audioTrackCount: 1)
        defer { try? FileManager.default.removeItem(at: silentSource) }
        let silent = AVURLAsset(url: silentSource)

        let composition = AVMutableComposition()
        let whole = CMTimeRange(start: .zero, duration: speechDuration)

        if let video = try await silent.loadTracks(withMediaType: .video).first,
           let track = composition.addMutableTrack(withMediaType: .video,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid) {
            try track.insertTimeRange(whole, of: video, at: .zero)
        }
        // System audio first — silent, and present so the mic is at index 1.
        if let quiet = try await silent.loadTracks(withMediaType: .audio).first,
           let track = composition.addMutableTrack(withMediaType: .audio,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid) {
            try track.insertTimeRange(whole, of: quiet, at: .zero)
        }
        if let voice = try await speech.loadTracks(withMediaType: .audio).first,
           let track = composition.addMutableTrack(withMediaType: .audio,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid) {
            try track.insertTimeRange(whole, of: voice, at: .zero)
        }

        let export = try #require(AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetPassthrough))
        try? FileManager.default.removeItem(at: bundle.captureURL)
        try await export.export(to: bundle.captureURL, as: .mov)

        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)
        try EventLog(events: []).write(to: bundle)
        try EditDecisionList.fullRange().write(to: bundle)
        return bundle
    }

    @Test("Speech in the microphone track comes back as timed words",
          .enabled(if: speechAuthorised, skipReason))
    func speechIsTranscribedWithTimings() async throws {
        let bundle = try await bundleWithSpeech()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        let transcript = try #require(try await Transcriber.transcribe(bundle: bundle),
                                      "nil means no microphone track — the fixture is wrong")
        #expect(!transcript.words.isEmpty, "no words came back from audible speech")

        // The words themselves, because a pipeline that returned plausible
        // timings attached to the wrong text would satisfy every structural
        // check below. Compared case-insensitively and without punctuation:
        // the recogniser is entitled to write "dog." and to capitalise.
        let spoken = transcript.words
            .map { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        for expected in ["quick", "brown", "fox", "lazy", "dog"] {
            #expect(spoken.contains(expected),
                    "\(expected) is missing from \(spoken.joined(separator: " "))")
        }
    }

    @Test("Word timings are ordered and inside the recording",
          .enabled(if: speechAuthorised, skipReason))
    func timingsAreUsable() async throws {
        // The transcript is a seek index and an edit surface (D62), so the
        // timings are the feature rather than decoration. Out-of-order or
        // out-of-range times would send the playhead somewhere wrong and
        // delete the wrong seconds, with the text still reading correctly.
        let bundle = try await bundleWithSpeech()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        let transcript = try #require(try await Transcriber.transcribe(bundle: bundle))
        let duration = try await AVURLAsset(url: bundle.captureURL).load(.duration).seconds

        #expect(transcript.words.allSatisfy { $0.start >= 0 },
                "a word starts before the recording does")
        #expect(transcript.words.allSatisfy { $0.start <= duration + 0.5 },
                "a word starts after the recording ends")
        #expect(transcript.words.allSatisfy { $0.duration > 0 },
                "a word has no duration, so it can never be the current word")

        let starts = transcript.words.map(\.start)
        #expect(starts == starts.sorted(),
                "words are out of order: \(starts)")
    }

    @Test("A recording with no microphone track transcribes to nil, not to empty",
          .enabled(if: speechAuthorised, skipReason))
    func noMicrophoneTrackIsNil() async throws {
        // Nil and "no words" mean different things to the pane: nil is "no way
        // to make a transcript", empty is "listened, heard nothing". Collapsing
        // them would make a mic-less recording claim it was silent.
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nomic-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 1.0)
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)

        let transcript = try await Transcriber.transcribe(bundle: bundle)
        #expect(transcript == nil)
    }
}
