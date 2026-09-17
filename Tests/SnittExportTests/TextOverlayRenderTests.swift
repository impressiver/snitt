// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AVFoundation
import CoreGraphics
import Foundation
@testable import SnittExport
@testable import SnittDocument

/// That captions and banners reach the PIXELS, in both formats.
///
/// The two routes are completely different — an animation tool on an
/// export-only composition for mp4, per-frame Core Graphics for GIF — so one
/// working says nothing about the other. `GIFExporter` already records that
/// failure for click rings: `AVAssetImageGenerator` ignores
/// `AVVideoComposition.animationTool` entirely, so a burn that worked for mp4
/// and silently did nothing for GIF hands the caller a file without the
/// captions they asked for.
///
/// Text is found by CONTRAST against the frame's own background, not by
/// absolute brightness — see `textCentroid` for why that distinction cost
/// three vacuous tests. That is the only claim these make about appearance; the timing is
/// `SubtitleCuesTests` and `MarkerBannersTests`.
struct TextOverlayRenderTests {

    /// Where the text is, measured as CONTRAST against the frame's own
    /// background rather than as absolute brightness.
    ///
    /// The first version of this asked for the brightest pixel and required it
    /// to clear a fixed threshold. `writeSyntheticMovie` renders a uniform grey
    /// of about 157, so EVERY pixel cleared it, `brightest` returned (0, 0) as
    /// the first of 76,800 equal maxima, and all three tests here passed
    /// against frames containing no text whatsoever. They were measuring the
    /// backdrop.
    ///
    /// Returns nil when nothing stands out, which is the answer that makes a
    /// missing overlay fail rather than pass.
    private func textCentroid(in image: CGImage) -> (x: Int, y: Int, pixels: Int)? {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &data, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var luma = [Int](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let p = i * 4
            luma[i] = (Int(data[p]) + Int(data[p + 1]) + Int(data[p + 2])) / 3
        }
        // The background is whatever most of the frame is.
        let background = luma.sorted()[luma.count / 2]

        // White text on the synthetic grey, and the banner's dark plate, are
        // both far from the median — so distance, not brightness.
        var sumX = 0, sumY = 0, count = 0
        for y in 0..<height {
            for x in 0..<width where abs(luma[y * width + x] - background) > 60 {
                sumX += x; sumY += y; count += 1
            }
        }
        guard count > 20 else { return nil }
        return (sumX / count, sumY / count, count)
    }

    /// 1280x720, not the fixture's 320x240 default.
    ///
    /// Overlay sizes are RELATIVE to the picture — `OverlayLayout` gives a
    /// caption 3.4% of the frame's height, with a 12pt floor — so a tiny frame
    /// does not merely shrink the caption, it moves the whole measurement into
    /// the noise. At 320x240 the caption renders at the 12pt floor and comes
    /// through H.264 as SEVENTEEN pixels of contrast; `textCentroid` requires
    /// twenty before it will believe it is looking at text rather than
    /// compression artefacts.
    ///
    /// Which is exactly how these tests failed on Xcode 27 while real exports
    /// were fine: measured on a real 3840-wide export of the same code, the
    /// captions and banners are present and correctly placed. The encoder
    /// moved a marginal signal a few pixels, and the fixture had no margin to
    /// give. 1280x720 is a size Snitt actually exports at, and the same
    /// caption lands with 502 pixels — twenty-five times the floor.
    private static let renderSize = CGSize(width: 1280, height: 720)

    private func bundleWithMovie(seconds: Double) async throws -> SnittBundle {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "textoverlay-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds,
                                      size: Self.renderSize)
        return bundle
    }

    @Test("An mp4 export carries the caption, near the bottom of the frame")
    func mp4CarriesTheCaption() async throws {
        let bundle = try await bundleWithMovie(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)

        let cues = [SubtitleCue(start: 0.2, end: 1.8, text: "HELLO")]
        let out = FileManager.default.temporaryDirectory
            .appending(path: "cap-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        try await MovieExporter.exportMovie(built, to: out, cues: cues)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: out))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(
            at: CMTime(seconds: 1.0, preferredTimescale: 600)).image

        let hit = try #require(textCentroid(in: frame), "no caption pixels in the mp4 at all")
        // Bottom third. The y check is what catches a coordinate flip, which
        // is the single most likely defect in a Core Animation layer tree and
        // is invisible to a "there is bright text somewhere" assertion.
        #expect(Double(hit.y) > Double(frame.height) * 0.6,
                "caption at y=\(hit.y) of \(frame.height) — expected near the bottom")
    }

    @Test("An mp4 export carries the marker banner, near the top LEFT")
    func mp4CarriesTheBanner() async throws {
        let bundle = try await bundleWithMovie(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)

        let banners = [MarkerBanner(appearsAt: 0.2, text: "NOTE", holdSeconds: 1.4)]
        let out = FileManager.default.temporaryDirectory
            .appending(path: "ban-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        try await MovieExporter.exportMovie(built, to: out, banners: banners)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: out))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Mid-hold, so the banner is at rest rather than mid-animation.
        let frame = try await generator.image(
            at: CMTime(seconds: 1.0, preferredTimescale: 600)).image

        let hit = try #require(textCentroid(in: frame), "no banner pixels in the mp4 at all")
        // BOTH axes, because the banner is the one element whose corner is the
        // whole design: a caption is centred, so only its y distinguishes it,
        // while a banner in the wrong corner passes every brightness check.
        #expect(Double(hit.y) < Double(frame.height) * 0.4,
                "banner at y=\(hit.y) of \(frame.height) — expected near the top")
        #expect(Double(hit.x) < Double(frame.width) * 0.5,
                "banner at x=\(hit.x) of \(frame.width) — expected on the left")
    }

    @Test("A GIF export carries them too — the animation tool does not apply here")
    func gifCarriesTheOverlays() async throws {
        // The failure `GIFExporter` warns about in its own comment:
        // `AVAssetImageGenerator` ignores `animationTool`, so the mp4 tests
        // above would both pass while every GIF shipped bare.
        let bundle = try await bundleWithMovie(seconds: 1.5)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)

        let out = FileManager.default.temporaryDirectory
            .appending(path: "gif-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: out) }
        try await GIFExporter.write(
            built, to: out, framesPerSecond: 10,
            cues: [SubtitleCue(start: 0, end: 1.5, text: "HELLO")],
            banners: [MarkerBanner(appearsAt: 0, text: "NOTE", holdSeconds: 1.2)])

        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        #expect(CGImageSourceGetCount(source) > 1, "the GIF has no frames to check")
        let frame = try #require(CGImageSourceCreateImageAtIndex(source, 5, nil))
        #expect(textCentroid(in: frame) != nil, "the GIF frame carries no overlay pixels")
    }

    @Test("With nothing to draw, the export is left alone")
    func noOverlaysMeansNoComposition() async throws {
        // Returning an empty composition instead of nil would attach an
        // animation tool for no reason — forcing a re-encode of every frame,
        // and disqualifying the passthrough path for a document that asked
        // for no overlays at all.
        let bundle = try await bundleWithMovie(seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        #expect(TextOverlayComposition.composition(
            from: built.videoComposition, cues: [], banners: []) == nil)
    }
}
