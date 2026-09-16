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
    /// How long the take is, tracked across pauses — see `TakeClock`.
    private var clock = TakeClock()
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
        let duration = clock.length(recorderTime: recorder.currentTime)
        recorder.stop()
        self.recorder = nil
        isRecording = false
        clock = TakeClock()
        return duration
    }

    /// Suspends the take without ending it (D102's transport).
    ///
    /// `AVAudioRecorder.pause()` keeps the file open and appends on the next
    /// `record()`, so a paused-and-resumed take is ONE continuous file — which
    /// is what lets `OverdubPlacement.segments(runs:)` treat file offsets as
    /// cumulative while output times jump.
    ///
    /// Returns how much audio is in the file so far, so the caller can close
    /// off the run that just ended. `currentTime` rather than wall clock: it
    /// is the recorder's own count of what it has written, and a wall clock
    /// includes the moment before the first sample.
    @discardableResult
    public func pause() -> Double? {
        guard let recorder, isRecording else { return nil }
        let elapsed = recorder.currentTime
        recorder.pause()
        // Remembered BEFORE the pause takes effect, because afterwards the
        // recorder reports 0 and the length is unrecoverable.
        clock.pause(at: elapsed)
        return elapsed
    }

    /// Carries on into the same take and the same file.
    ///
    /// Returns false when there is nothing to resume, so a caller cannot
    /// silently believe a take is running when none is.
    @discardableResult
    public func resume() -> Bool {
        guard let recorder, isRecording else { return false }
        return recorder.record()
    }
}

/// How long a take is, across pauses.
///
/// A value type rather than two fields on the recorder, and that is the point:
/// `AVAudioRecorder` needs an input device, so it cannot be driven on a test
/// runner at all — and the bookkeeping around it was therefore the one part of
/// this that nothing could assert. Extracting it moves the rule AND the
/// remembering somewhere a test can reach.
///
/// The defect it exists for was reported as "the punch in didn't actually
/// record anything". It had: the audio was written and the file was on disk.
/// `AVAudioRecorder.currentTime` is documented as 0 when the recorder is not
/// recording, `pause()` makes it not recording, and stopping a paused take
/// therefore measured it as zero seconds long — so the guard that throws away
/// accidental taps threw away the take.
struct TakeClock: Equatable {
    /// How much audio was in the file when it was last paused.
    private(set) var pausedElapsed: Double = 0

    /// Records the length at the moment of a pause, BEFORE the recorder stops
    /// being able to report it.
    mutating func pause(at elapsed: Double) { pausedElapsed = elapsed }

    /// The take's length, from the two things that can know.
    ///
    /// The LARGER, and neither alone: a running recorder knows its own time
    /// and a paused one reports 0, while `pausedElapsed` is the truth for a
    /// paused take and stale for a running one that has been resumed since.
    func length(recorderTime: Double) -> Double { max(recorderTime, pausedElapsed) }
}
