// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
import AVFoundation
@testable import SnittExport

/// Thumbnails for the timeline's video track.
///
/// The assertion that matters is that different points in the recording produce
/// DIFFERENT frames. A sampler that returned the first frame N times, or N
/// copies of one image, yields a filmstrip that looks entirely plausible — and
/// every structural check (count, spacing, aspect) still passes.
@Suite
struct FilmstripSamplerTests {
    private func movie(seconds: Double, content: SyntheticFrameContent = .ramp) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "filmstrip-\(UUID().uuidString).mov")
        try await writeSyntheticMovie(to: url, seconds: seconds, content: content)
        return url
    }

    @Test("Frames from different moments actually differ")
    func framesDiffer() async throws {
        // `.ramp` fills each frame with a value derived from its index, so
        // "which moment is this" is observable in the pixels.
        let url = try await movie(seconds: 3.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let strip = try await FilmstripSampler.sample(movieAt: url, maxFrames: 6, height: 32)
        #expect(strip.frames.count >= 3, "expected several thumbnails, got \(strip.frames.count)")

        let first = try #require(meanLuma(strip.frames.first))
        let last = try #require(meanLuma(strip.frames.last))
        #expect(abs(first - last) > 5,
                "every thumbnail is the same frame — luma \(first) vs \(last)")
    }

    @Test("The frame count is capped rather than growing with duration")
    func frameCountIsCapped() async throws {
        // Unbounded sampling means a ten-minute recording decodes hundreds of
        // frames to draw a strip a few hundred pixels wide.
        let url = try await movie(seconds: 4.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let strip = try await FilmstripSampler.sample(movieAt: url, maxFrames: 3, height: 32)
        #expect(strip.frames.count <= 3)
        #expect(strip.samplesPerSecond > 0)
    }

    @Test("samplesPerSecond describes the spacing actually used")
    func rateMatchesSpacing() async throws {
        // The drawing side converts a source time to an index with this rate,
        // so a rate that disagrees with the real spacing puts the wrong frame
        // under the playhead — silently, and only visibly on a long recording.
        let url = try await movie(seconds: 4.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let strip = try await FilmstripSampler.sample(movieAt: url, maxFrames: 8, height: 32)
        let impliedDuration = Double(strip.frames.count) / strip.samplesPerSecond
        #expect(abs(impliedDuration - 4.0) < 1.0,
                "rate implies a \(impliedDuration)s recording, actual 4s")
    }

    private func meanLuma(_ image: CGImage?) -> Double? {
        guard let image, let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data), image.height > 0 else { return nil }
        var total = 0.0, count = 0.0
        for y in stride(from: 0, to: image.height, by: 2) {
            for x in stride(from: 0, to: image.width, by: 2) {
                total += Double(bytes[y * image.bytesPerRow + x * 4]); count += 1
            }
        }
        return count > 0 ? total / count : nil
    }
}
