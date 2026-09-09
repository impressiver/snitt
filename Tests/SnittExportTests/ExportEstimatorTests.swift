import AVFoundation
import Foundation
import Testing
@testable import SnittDocument
@testable import SnittExport

/// Choosing a resolution before paying for the export.
@Suite
struct ExportEstimatorTests {

    private func makeBundle(seconds: Double, size: CGSize = CGSize(width: 1280, height: 720))
        async throws -> SnittBundle {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "est-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds,
                                      size: size, content: .blankThenBands)
        return bundle
    }

    @Test("The menu offers every resolution, largest first")
    func menuIsCompleteAndOrdered() async throws {
        let bundle = try await makeBundle(seconds: 3.0)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let menu = try await ExportEstimator.menu(bundle: bundle, edl: EditDecisionList())

        #expect(menu.map(\.resolution) == ExportResolution.descending,
                "got \(menu.map(\.resolution.rawValue))")
        // Descending is the direction someone walks while trying to fit a
        // budget; presenting it any other way makes them re-sort it.
        let longEdges = menu.map { max($0.width, $0.height) }
        #expect(longEdges == longEdges.sorted(by: >), "not ordered by size: \(longEdges)")
    }

    @Test("A resolution never enlarges the recording")
    func presetsDoNotUpscale() async throws {
        // 720p source. Asking for 2160p adds pixels and no information, so it
        // must come back at what the recording actually has.
        let bundle = try await makeBundle(seconds: 3.0, size: CGSize(width: 1280, height: 720))
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let menu = try await ExportEstimator.menu(bundle: bundle, edl: EditDecisionList())
        let big = try #require(menu.first { $0.resolution == .uhd2160p })
        #expect(big.width == 1280 && big.height == 720,
                "upscaled to \(big.width)x\(big.height)")
    }

    @Test("A smaller resolution never claims to cost more")
    func estimatesDoNotIncreaseAsSizeDrops() async throws {
        // The one property a chooser must have. Without it the menu can
        // recommend shrinking and then charge more for it — which is real
        // behaviour for `--scale` on some recordings, and is exactly why the
        // knob is a resolution rather than a multiplier.
        let bundle = try await makeBundle(seconds: 3.0, size: CGSize(width: 1920, height: 1080))
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let menu = try await ExportEstimator.menu(bundle: bundle, edl: EditDecisionList())
        let bytes = menu.map(\.estimatedMaxBytes)
        #expect(bytes == bytes.sorted(by: >=), "not monotonic: \(bytes)")
    }

    @Test("The ceiling holds: a real export comes in under it")
    func theCeilingIsACeiling() async throws {
        let bundle = try await makeBundle(seconds: 4.0)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let edl = EditDecisionList()
        for resolution in [ExportResolution.source, .hd720p, .sd480p] {
            let estimate = try await ExportEstimator.estimate(
                bundle: bundle, edl: edl, resolution: resolution)
            let out = FileManager.default.temporaryDirectory
                .appending(path: "est-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: out) }
            let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
            try await MovieExporter.exportMovie(built, to: out, resolution: resolution)
            let actual = try #require(
                FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int)
            #expect(actual <= estimate.estimatedMaxBytes,
                    "\(resolution.rawValue): exported \(actual), ceiling was \(estimate.estimatedMaxBytes)")
        }
    }

    @Test("Duration is exact, and follows the cuts")
    func durationIsExact() async throws {
        let bundle = try await makeBundle(seconds: 8.0)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let edl = EditDecisionList(cuts: [Cut(range: TimeRange(start: 0, end: 2))])
        let estimate = try await ExportEstimator.estimate(
            bundle: bundle, edl: edl, resolution: .source)
        #expect(abs(estimate.durationSeconds - 6.0) < 0.2,
                "got \(estimate.durationSeconds), expected the 6s that survive")
    }

    @Test("GIF is refused rather than answered from the wrong codec")
    func gifIsRefused() async throws {
        // The estimator describes an H.264 export. GIF has no interframe
        // compression and its size tracks how much the picture moves, so the
        // number would be meaningless rather than merely imprecise.
        let bundle = try await makeBundle(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        await #expect(throws: EstimateError.unsupportedFormat("gif")) {
            try await ExportEstimator.estimate(
                bundle: bundle, edl: EditDecisionList(), resolution: .source, format: "gif")
        }
    }

    @Test("The manifest reports the size the FILE is, not the composition's")
    func manifestReportsTheWrittenSize() async throws {
        // Found by exporting a real 5K recording at 720p: the file was
        // 1280x804 and the manifest said 4112x2580, because it read the
        // composition's renderSize and a resolution preset resizes AFTER that.
        // The manifest is what an agent quotes to describe a demo it cannot
        // watch, so it has to describe the demo.
        let bundle = try await makeBundle(seconds: 3.0, size: CGSize(width: 1920, height: 1080))
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let out = FileManager.default.temporaryDirectory
            .appending(path: "manifest-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }

        let manifest = try await MovieExporter.export(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0, to: out,
            resolution: .hd720p)

        let track = try #require(try await AVURLAsset(url: out)
            .loadTracks(withMediaType: .video).first)
        let actual = try await track.load(.naturalSize)
        #expect(manifest.width == Int(actual.width) && manifest.height == Int(actual.height),
                "manifest says \(manifest.width)x\(manifest.height), file is \(Int(actual.width))x\(Int(actual.height))")
        // And it really did shrink — a manifest that matched the file would
        // also pass if the preset had been ignored entirely.
        #expect(manifest.width < 1920, "the 720p preset did not resize: \(manifest.width)")
    }

    @Test("The basis says the ceiling is generous, so nobody plans a budget on it")
    func basisDisclosesLooseness() async throws {
        // Measured at ~4x the real file on a 5K recording. A ceiling that
        // reads as a prediction is one somebody sizes an attachment against.
        let bundle = try await makeBundle(seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let estimate = try await ExportEstimator.estimate(
            bundle: bundle, edl: EditDecisionList(), resolution: .source)
        let basis = estimate.basis.lowercased()
        #expect(basis.contains("generous") || basis.contains("ceiling"),
                "the basis does not warn how loose it is: \(estimate.basis)")
    }
}
