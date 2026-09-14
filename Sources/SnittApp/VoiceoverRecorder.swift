// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AVFoundation
import Foundation
import SnittCapture
import SnittDocument

/// Records narration to a file beside the capture (D93).
///
/// `AVAudioRecorder`, not the `SCStream` path the recorder uses. There is no
/// screen to capture here and no second track to keep in sync — it is one
/// microphone writing one file — and reusing the capture stack would drag in
/// content filters, a picker and a session cap for a job that needs none of
/// them.
///
/// **It never touches `capture.mov`.** §4.5 makes the capture immutable, so
/// narration is its own asset and the composition places it. Re-recording
/// replaces the file wholesale, which is why `start` refuses when one is
/// already running rather than interleaving two.
@MainActor
public final class VoiceoverRecorder {
    public enum StartFailure: Equatable {
        /// The microphone permission was refused, or has not been granted.
        case microphoneDenied
        /// Something else is already recording narration.
        case alreadyRecording
        /// AVFoundation refused to start, with its own message.
        case failed(String)
    }

    public init() {}

    private var recorder: AVAudioRecorder?
    public private(set) var isRecording = false
    /// Where in the OUTPUT timeline the current take began. Captured at start,
    /// because the playhead moves while narration is being spoken and the
    /// anchor is where it STARTED.
    public private(set) var startedAtOutput: Double = 0

    /// Level per sample taken, newest last, for the lane drawn while
    /// recording.
    ///
    /// Accumulated here rather than derived afterwards, because there IS no
    /// afterwards while a take is running: the file is still being written and
    /// cannot be decoded. Without this the only feedback that narration is
    /// being captured is that the picture is playing, which is exactly what
    /// playing it without recording looks like — the reason this was reported
    /// as "nothing gets recorded".
    public private(set) var levels: [Float] = []

    /// Takes one level reading. Called by the editor's existing playhead
    /// poll, so the lane advances at the same rate the playhead does and the
    /// two cannot drift apart.
    public func sampleLevel() {
        guard let recorder, isRecording else { return }
        recorder.updateMeters()
        // dBFS to a 0...1 magnitude, on the same curve a waveform is drawn
        // with. -60 dB is the floor: below that is room tone, and mapping it
        // linearly would make silence look like quiet speech.
        let decibels = Double(recorder.averagePower(forChannel: 0))
        let magnitude = decibels <= -60 ? 0 : pow(10, decibels / 20)
        levels.append(Float(magnitude))
    }

    /// Begins a take, writing to `url`.
    ///
    /// - Parameter ensureMicrophone: injected so a test can exercise the
    ///   refusal without a real TCC prompt, which is per-machine and one-shot.
    public func start(writingTo url: URL,
               fromOutputSeconds outputStart: Double,
               ensureMicrophone: () -> Bool = { MicrophoneAccess.ensureGranted() })
        -> StartFailure? {
        guard !isRecording else { return .alreadyRecording }
        guard ensureMicrophone() else { return .microphoneDenied }

        // AAC in an m4a, matching what `AssetWriterSink` writes for the
        // capture's own audio: one decoder for every audio track in the
        // bundle, and a file QuickTime opens on its own if anyone looks.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        do {
            // Removed first: `AVAudioRecorder` appends to an existing file at
            // some sample rates and overwrites at others, and "sometimes the
            // old take is still in there" is not a behaviour worth having.
            try? FileManager.default.removeItem(at: url)
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            // Before `record()`: metering enabled afterwards returns zero
            // until the next start, so the lane would stay flat for the whole
            // take with nothing to explain why.
            recorder.isMeteringEnabled = true
            guard recorder.record() else { return .failed("the recorder would not start") }
            levels.removeAll(keepingCapacity: true)
            self.recorder = recorder
            isRecording = true
            startedAtOutput = outputStart
            return nil
        } catch {
            return .failed((error as NSError).localizedDescription)
        }
    }

    /// Ends the take and returns how long it ran, or nil if nothing was
    /// recording.
    ///
    /// The duration comes from the RECORDER rather than from a wall clock
    /// started at `start`. A wall clock measures how long the button was held,
    /// which includes the moment before the first sample and drifts from what
    /// is actually in the file — and the file's length is what the placement
    /// arithmetic has to agree with.
    @discardableResult
    public func stop() -> Double? {
        guard let recorder, isRecording else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        isRecording = false
        return duration
    }
}
