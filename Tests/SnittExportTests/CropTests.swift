import Testing
import Foundation
import AVFoundation
import CoreImage
@testable import SnittExport
@testable import SnittDocument

// Crop (§13 item 1, D64 as corrected by the 2026-09-07 refinement pass).
//
// Crop is a layer-instruction transform plus a smaller renderSize — not a
// custom compositor and not AVVideoCompositionCoreAnimationTool. That matters
// beyond cost: a geometric transform applies in AVPlayerItem playback as well
// as export, so the editor previews a crop live and §9's one-builder guarantee
// holds with no exception carved for it.
//
// The load-bearing test here is `cropSelectsTheRequestedQuadrant`. Asserting
// output DIMENSIONS cannot distinguish a correct crop from one with a flipped
// y axis or a transposed origin — every one of those produces identically-sized
// output. Only reading the pixels back settles which region survived, which is
// also how the coordinate convention was established rather than assumed.
@Suite
struct CropTests {
    private func makeBundle(content: SyntheticFrameContent = .quadrants,
                            size: CGSize = CGSize(width: 320, height: 240)) async throws -> SnittBundle {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "crop-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 1.0, size: size, content: content)
        return bundle
    }

    /// Mean luma of the exported movie's first frame.
    private func luma(of url: URL) async throws -> Double {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let (image, _) = try await generator.image(at: CMTime(value: 1, timescale: 10))
        let context = CIContext()
        let ci = CIImage(cgImage: image)
        var total = 0.0, count = 0.0
        guard let bitmap = context.createCGImage(ci, from: ci.extent),
              let data = bitmap.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return -1 }
        let bpr = bitmap.bytesPerRow
        // Sample the interior only: H.264 rings at hard edges, and a crop
        // boundary is a hard edge, so including the border would measure the
        // codec rather than the crop.
        for y in stride(from: bitmap.height / 4, to: bitmap.height * 3 / 4, by: 2) {
            for x in stride(from: bitmap.width / 4, to: bitmap.width * 3 / 4, by: 2) {
                total += Double(bytes[y * bpr + x * 4]); count += 1
            }
        }
        return count > 0 ? total / count : -1
    }

    @Test("A crop shrinks the render to exactly the requested fraction")
    func cropShrinksTheRender() async throws {
        let bundle = try await makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let edl = EditDecisionList(crop: CropRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25))
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        #expect(built.videoComposition.renderSize == CGSize(width: 160, height: 60))
    }

    @Test("Crop composes with scale")
    func cropComposesWithScale() async throws {
        let bundle = try await makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let edl = EditDecisionList(crop: CropRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 0.5)
        // 320x240 -> crop to 160x120 -> scale to 80x60. Order must not matter.
        #expect(built.videoComposition.renderSize == CGSize(width: 80, height: 60))
    }

    @Test("A full-frame crop renders identically to no crop")
    func fullFrameCropIsANoOp() async throws {
        let bundle = try await makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let uncropped = try await CompositionBuilder.build(bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let full = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(crop: .full), scale: 1.0)
        #expect(uncropped.videoComposition.renderSize == full.videoComposition.renderSize)
    }

    @Test("Cropping to a quadrant selects THAT quadrant, not a same-sized different one")
    func cropSelectsTheRequestedQuadrant() async throws {
        // The whole point of the fixture. Each quadrant has a distinct luma, so
        // a flipped y axis (bottom-right instead of top-right) or a transposed
        // origin (bottom-left) fails here while every dimension assertion above
        // still passes.
        let bundle = try await makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        let cases: [(String, CropRect, Int)] = [
            ("top-left", CropRect(x: 0, y: 0, width: 0.5, height: 0.5), quadrantTopLeft),
            ("top-right", CropRect(x: 0.5, y: 0, width: 0.5, height: 0.5), quadrantTopRight),
            ("bottom-left", CropRect(x: 0, y: 0.5, width: 0.5, height: 0.5), quadrantBottomLeft),
            ("bottom-right", CropRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), quadrantBottomRight),
        ]
        for (name, rect, expected) in cases {
            let out = FileManager.default.temporaryDirectory
                .appending(path: "crop-\(name)-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: out) }
            let built = try await CompositionBuilder.build(
                bundle: bundle, edl: EditDecisionList(crop: rect), scale: 1.0)
            try await MovieExporter.exportMovie(built, to: out)
            let measured = try await luma(of: out)
            #expect(abs(measured - Double(expected)) < 16,
                    "\(name): expected luma ~\(expected), measured \(measured)")
        }
    }
}

// Crop set anywhere must reach the export, since export reads edit.json through
// the same CompositionBuilder the editor previews with (§9). If this ever
// fails, the GUI and the CLI have two different models — D60's finding.
@Suite
struct CropExportTests {
    @Test("Exporting a bundle whose edit.json carries a crop produces cropped video")
    func exportHonoursCropOnDisk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "crop-export-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 1.0,
                                      size: CGSize(width: 320, height: 240))
        // Written to DISK, then read back — not passed in memory. The failure
        // this guards is a crop that persists but never reaches a render.
        try EditDecisionList(crop: CropRect(x: 0, y: 0, width: 0.5, height: 0.5))
            .write(to: bundle)

        let edl = try EditDecisionList.read(from: bundle)
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        #expect(built.videoComposition.renderSize == CGSize(width: 160, height: 120))

        let out = FileManager.default.temporaryDirectory
            .appending(path: "crop-export-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        try await MovieExporter.exportMovie(built, to: out)

        let track = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 160, height: 120),
                "the exported file is not cropped: \(size)")
    }
}
