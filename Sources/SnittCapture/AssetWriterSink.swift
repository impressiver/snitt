// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import AVFoundation
import CoreMedia

/// Writes sample buffers into a QuickTime movie with three tracks.
///
/// Movie fragments are flushed periodically so that a crash mid-recording
/// leaves a playable file rather than an unreadable one (spec section 9).
public final class AssetWriterSink: SampleBufferSink, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let inputs: [TrackKind: AVAssetWriterInput]
    private let lock = NSLock()
    private var started = false
    private var finished = false

    /// §12.1: sampling rides the existing pass — there is no second decode.
    public let health = HealthSampler()

    /// Count of video buffers the writer actually accepted (as opposed to
    /// ones offered via `append` but silently dropped because the input
    /// was not ready). Exists so callers — tests included — can tell how
    /// much media time has actually landed, since `append` returning does
    /// not mean the buffer was taken (see the comment at the drop site).
    private var acceptedVideoFrames = 0
    public func acceptedVideoFrameCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return acceptedVideoFrames
    }

    /// How often an unfinalized movie flushes a fragment.
    ///
    /// Public so a test can key its expectations off the REAL value instead of
    /// restating it. `unfinalizedFileHasBytesOnDisk` has to push more than this
    /// much media through before a flush can possibly have happened, and it
    /// previously hardcoded a frame count that stood in for two seconds. A
    /// second copy of a constant drifts: changing this interval would have left
    /// that test asserting against the old one, still passing, and no longer
    /// testing what it says.
    public static let movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

    public init(outputURL: URL, videoSize: CGSize) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        // Flush a fragment every second. Without this, an unfinalized movie
        // has no moov atom and cannot be played at all.
        writer.movieFragmentInterval = Self.movieFragmentInterval

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(videoSize.width),
                AVVideoHeightKey: Int(videoSize.height),
            ]
        )
        videoInput.expectsMediaDataInRealTime = true

        func makeAudioInput() -> AVAssetWriterInput {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 128_000,
                ]
            )
            input.expectsMediaDataInRealTime = true
            return input
        }

        let systemInput = makeAudioInput()
        let micInput = makeAudioInput()

        // This order — video, then systemInput, then micInput — is load-bearing:
        // it determines the audio track order the exporter's `AudioMix` matches
        // states against. See `SnittDocument.AudioTrackOrder.canonical`, which
        // names it explicitly rather than leaving `SnittExport` to infer it from
        // this loop.
        for input in [videoInput, systemInput, micInput] {
            guard writer.canAdd(input) else {
                throw SinkError.writerFailed("cannot add input \(input.mediaType)")
            }
            writer.add(input)
        }

        inputs = [
            .video: videoInput,
            .systemAudio: systemInput,
            .microphone: micInput,
        ]
    }

    public func begin(at startTime: CMTime) throws {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        guard writer.startWriting() else {
            throw SinkError.writerFailed(
                writer.error?.localizedDescription ?? "startWriting failed"
            )
        }
        writer.startSession(atSourceTime: startTime)
        started = true
    }

    public func append(_ buffer: CMSampleBuffer, to track: TrackKind) throws {
        lock.lock(); defer { lock.unlock() }
        guard started else { throw SinkError.notStarted }
        guard !finished else { throw SinkError.alreadyFinished }
        guard let input = inputs[track] else { return }

        // Measured only once the buffer is one this sink will actually take.
        // Observing before the guards folded rejected buffers — appended
        // before `begin`, or after `finish` — into §12.1's metrics, so the
        // health of a recording included frames and audio that are not in it.
        health.observe(buffer, track: track)

        // Dropping when not ready is correct: back-pressure from the encoder
        // must never block ScreenCaptureKit's delivery queue.
        guard input.isReadyForMoreMediaData else { return }
        input.append(buffer)
        if track == .video { acceptedVideoFrames += 1 }
    }

    /// Synchronous helper so the lock is never held across an `await`
    /// suspension point (NSLock's lock/unlock are unavailable from async
    /// contexts). This flips `finished` to true and marks inputs finished
    /// atomically, so a concurrent `append` that runs after this returns
    /// is guaranteed to observe `finished` and throw `.alreadyFinished`
    /// rather than appending to a writer that is being torn down.
    private func beginFinishing() throws {
        lock.lock(); defer { lock.unlock() }
        guard started, !finished else {
            throw finished ? SinkError.alreadyFinished : SinkError.notStarted
        }
        finished = true
        for input in inputs.values { input.markAsFinished() }
    }

    public func finish() async throws -> URL {
        try beginFinishing()

        await writer.finishWriting()

        if writer.status == .failed {
            throw SinkError.writerFailed(
                writer.error?.localizedDescription ?? "unknown writer failure"
            )
        }
        return writer.outputURL
    }
}
