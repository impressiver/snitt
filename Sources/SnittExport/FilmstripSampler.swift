// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AVFoundation
import CoreGraphics
import Foundation

/// Thumbnails of the recording, evenly spaced in SOURCE time.
///
/// Same contract as `WaveformSamples`, for the same reason: sampled once
/// against `capture.mov`, indexed per pixel column afterwards, so cuts and zoom
/// cost nothing and the movie is decoded once per document rather than once per
/// edit.
///
/// `@unchecked Sendable` because `CGImage` is not formally `Sendable` but is
/// immutable once created — these are handed across an actor boundary read-only
/// and never mutated. The alternative is redrawing every thumbnail on the main
/// actor, which is the work this type exists to move off it.
public struct FilmstripFrames: @unchecked Sendable {
    /// Frames per source second — the reciprocal of the sampling interval.
    public let samplesPerSecond: Double
    public let frames: [CGImage]

    public init(samplesPerSecond: Double, frames: [CGImage]) {
        self.samplesPerSecond = samplesPerSecond
        self.frames = frames
    }
}

public enum FilmstripSampler {
    /// Decodes up to `maxFrames` thumbnails spread evenly across the recording.
    ///
    /// Capped rather than sampled at a fixed rate: a fixed rate means a
    /// ten-minute recording decodes six hundred frames to draw a strip a few
    /// hundred pixels wide. The cap bounds both the decode and the memory, and
    /// at high zoom the same thumbnail simply repeats across several columns —
    /// which is what a filmstrip does anyway.
    public static func sample(movieAt url: URL,
                              maxFrames: Int = 120,
                              height: Int = 64) async throws -> FilmstripFrames {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, maxFrames > 0 else {
            return FilmstripFrames(samplesPerSecond: 0, frames: [])
        }

        let count = max(1, min(maxFrames, Int(duration.rounded(.up)) * 2))
        let interval = duration / Double(count)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 0, height: CGFloat(height))
        // A filmstrip wants speed, not frame accuracy: any frame near the mark
        // reads the same at thumbnail size, and exact seeking would decode
        // every intervening frame.
        generator.requestedTimeToleranceBefore = CMTime(seconds: interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: interval / 2, preferredTimescale: 600)

        var frames: [CGImage] = []
        for index in 0..<count {
            let time = CMTime(seconds: Double(index) * interval + interval / 2,
                              preferredTimescale: 600)
            // One unreadable frame must not lose the whole strip — a recording
            // that ends mid-write (§11) can have a decodable head and a broken
            // tail, and a partial filmstrip beats none.
            guard let image = try? await generator.image(at: time).image else { break }
            frames.append(image)
        }
        return FilmstripFrames(samplesPerSecond: 1 / interval, frames: frames)
    }
}
