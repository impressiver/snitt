// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AVFoundation
import Foundation
import SnittDocument

/// Peak amplitudes for one audio track, in SOURCE time.
///
/// Sampled against `capture.mov`, never against the trimmed composition. That
/// is the whole design: a cut, a zoom, or a scroll changes which source instant
/// each pixel column shows, not what the audio at that instant looks like — so
/// the expensive read happens once per document and every later edit is a
/// lookup. Sampling the composition instead would mean re-reading the movie on
/// every trim.
public struct WaveformSamples: Sendable, Equatable {
    /// `"microphone"` or `"systemAudio"` — the same names `TrackState` uses.
    public let track: String
    public let samplesPerSecond: Double
    /// Peak magnitude per bucket, RAW — not clamped to 1.
    ///
    /// Clamping here would erase clipping before anything could draw it: a
    /// bucket that reached digital full scale and one that sailed past it are
    /// different facts, and the second is what a clipping indicator exists to
    /// report. `WaveformScale` clamps at draw time, where the information has
    /// already been used.
    public let peaks: [Float]

    public init(track: String, samplesPerSecond: Double, peaks: [Float]) {
        self.track = track
        self.samplesPerSecond = samplesPerSecond
        self.peaks = peaks
    }
}

public enum WaveformSampler {
    /// Reads every audio track in `url` and returns one `WaveformSamples` each,
    /// named by `AudioTrackOrder.canonical`.
    ///
    /// Names come from that shared order rather than from track index guessing:
    /// `AssetWriterSink` writes audio as `[systemAudio, microphone]` while
    /// `EditDecisionList.fullRange()` lists `["video", "microphone",
    /// "systemAudio"]`, and index-matching those two is the exact defect that
    /// once made muting system audio do nothing and muting "video" silence it.
    public static func sample(movieAt url: URL,
                              samplesPerSecond: Double = 60) async throws -> [WaveformSamples] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var result: [WaveformSamples] = []
        for (index, track) in tracks.enumerated() {
            guard index < AudioTrackOrder.canonical.count else { break }
            let peaks = try await peaks(of: track, in: asset, samplesPerSecond: samplesPerSecond)
            result.append(WaveformSamples(track: AudioTrackOrder.canonical[index],
                                          samplesPerSecond: samplesPerSecond,
                                          peaks: peaks))
        }
        return result
    }

    private static func peaks(of track: AVAssetTrack,
                              in asset: AVAsset,
                              samplesPerSecond: Double) async throws -> [Float] {
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return [] }
        let sampleRate = basic.mSampleRate > 0 ? basic.mSampleRate : 48_000
        let framesPerBucket = max(1, Int((sampleRate / samplesPerSecond).rounded()))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        var peaks: [Float] = []
        var bucketPeak: Float = 0
        var framesInBucket = 0

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length,
                                              dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                  let pointer else { continue }
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { samples in
                // Interleaved: every channel's sample contributes to the same
                // bucket, so a loud right channel is not averaged away by a
                // quiet left one. A waveform is about whether there is signal.
                for i in 0..<count {
                    bucketPeak = max(bucketPeak, abs(samples[i]))
                    framesInBucket += 1
                    if framesInBucket >= framesPerBucket * Int(max(1, basic.mChannelsPerFrame)) {
                        peaks.append(bucketPeak)
                        bucketPeak = 0
                        framesInBucket = 0
                    }
                }
            }
        }
        if framesInBucket > 0 { peaks.append(bucketPeak) }

        // A reader that failed partway has given us a truncated waveform, which
        // would silently draw as "the recording goes quiet here". Report
        // nothing rather than something wrong.
        if reader.status == .failed { return [] }
        return peaks
    }
}
