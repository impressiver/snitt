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

        // Across ALL the thumbnails, not first-versus-last.
        //
        // `.ramp` fills a frame with `20 + (index * 7) % 200` — a SAWTOOTH,
        // not a ramp — so luma is not injective in time, and "two different
        // moments" does not imply "two different lumas". In a 90-frame movie
        // exactly two indices land within 5 of frame 0: 29 and 86. Frame 86
        // reads 22 against frame 0's 20, and a run whose last sample resolved
        // to 86 instead of 89 failed this test with a difference of 2.0119 —
        // in the full gate, passing in isolation, which is the signature this
        // suite has been misread as load flakiness for before.
        //
        // The spread over every sampled frame cannot wrap onto itself the way
        // one pair can, and it still fails for the reason this test exists: a
        // sampler that returned one frame N times gives a spread of zero.
        let lumas = try strip.frames.map { try #require(meanLuma($0)) }
        let spread = try #require(lumas.max()) - #require(lumas.min())
        #expect(spread > 5, "every thumbnail is the same frame — lumas \(lumas)")
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
