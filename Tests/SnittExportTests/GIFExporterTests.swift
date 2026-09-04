import Testing
import AVFoundation
import ImageIO
import Foundation
@testable import SnittExport
import SnittDocument

/// A tiny real movie, so the exporter is exercised against AVFoundation
/// rather than a mock that cannot disagree with it.
///
/// Duplicated from `MovieExporterTests.swift`/`CompositionBuilderTests.swift`
/// deliberately, matching the convention already established there: this
/// file needs its own private copy (Swift Testing target sources don't share
/// private helpers across files without a shared internal type), and
/// `writeSyntheticMovie` in `SyntheticMovie.swift` already does the real
/// work. `size:` is threaded through here (the other files' copies do not
/// need it) because `gifHonoursScale` must exercise scale against a known
/// source size.
private func makeTestBundle(seconds: Double = 4,
                             size: CGSize = CGSize(width: 320, height: 240),
                             audioTrackCount: Int = 0) async throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds, size: size,
                                   audioTrackCount: audioTrackCount)
    return bundle
}

@Test("A GIF is written with one frame per requested interval")
func gifHasExpectedFrameCount() async throws {
    let bundle = try await makeTestBundle(seconds: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("g-\(UUID().uuidString).gif")
    defer { try? FileManager.default.removeItem(at: out) }

    try await GIFExporter.write(built, to: out, framesPerSecond: 5)

    let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
    // 2 seconds at 5fps = 10 frames. A generator that emits one frame, or
    // that ignores framesPerSecond, fails here.
    #expect(CGImageSourceGetCount(source) == 10)
    #expect(CGImageSourceGetType(source) as String? == "com.compuserve.gif")
}

@Test("The GIF loops forever and carries a per-frame delay")
func gifLoopsAndHasDelay() async throws {
    let bundle = try await makeTestBundle(seconds: 1)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("l-\(UUID().uuidString).gif")
    defer { try? FileManager.default.removeItem(at: out) }

    try await GIFExporter.write(built, to: out, framesPerSecond: 10)

    let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
    let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
    let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    // loopCount 0 means infinite. An encoder that omits the properties
    // dictionary writes a GIF that plays once — the discriminating case.
    #expect(gif?[kCGImagePropertyGIFLoopCount] as? Int == 0)

    let frame = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let frameGIF = frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    let delay = frameGIF?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
    #expect(delay != nil)
    #expect(abs((delay ?? 0) - 0.1) < 0.001)
}

@Test("Scale shrinks the GIF's pixel dimensions")
func gifHonoursScale() async throws {
    let bundle = try await makeTestBundle(seconds: 1, size: CGSize(width: 320, height: 240))
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 0.5)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("s-\(UUID().uuidString).gif")
    defer { try? FileManager.default.removeItem(at: out) }

    try await GIFExporter.write(built, to: out, framesPerSecond: 5)

    let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    // Ties the GIF's real pixels to the composition's renderSize. An encoder
    // that generates frames without assigning videoComposition produces
    // 320x240 here and passes every other test in this file.
    #expect(props?[kCGImagePropertyPixelWidth] as? Int == 160)
    #expect(props?[kCGImagePropertyPixelHeight] as? Int == 120)
}

@Test("A degenerate render size is refused rather than crashing the process")
func degenerateRenderSizeRefused() async throws {
    let bundle = try await makeTestBundle(seconds: 1)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let broken = BuiltComposition(
        composition: built.composition,
        videoComposition: AVMutableVideoComposition(),   // renderSize .zero
        duration: built.duration,
        keptRanges: built.keptRanges)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("d-\(UUID().uuidString).gif")
    defer { try? FileManager.default.removeItem(at: out) }

    // Assigning a zero-renderSize videoComposition to AVAssetImageGenerator
    // raises an ObjC NSException that Swift CANNOT catch — the test process
    // dies rather than failing. This test passing at all is the evidence
    // that the guard runs before the assignment.
    await #expect(throws: GIFError.degenerateRenderSize) {
        try await GIFExporter.write(broken, to: out, framesPerSecond: 5)
    }
}



@Test("A frame the generator cannot produce fails the export instead of silently truncating the GIF")
func unfulfillableFrameFailsExport() async throws {
    // §11: "Emitting a black or corrupt video is the worst possible
    // outcome." `images(for:)` delivers per-frame `.failure` results rather
    // than throwing — an implementation that does `case .failure: continue`
    // instead of throwing produces a GIF that is silently missing frames.
    // Verified against exactly that implementation: with duration inflated
    // 6x past the composition's real content, 25 of 30 requested frames
    // failed and were dropped, and the run still reported success with no
    // thrown error and a 5-frame file on disk.
    //
    // Inflating `duration` past the composition's actual content is the
    // most direct way to force AVAssetImageGenerator to fail specific
    // frames through the public API: requested times beyond what the
    // composition can produce come back as `.failure`, with
    // `requestedTimeToleranceBefore/After = .zero` ruling out silent
    // snapping to a nearby valid time.
    let bundle = try await makeTestBundle(seconds: 1)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let inflated = BuiltComposition(
        composition: built.composition,
        videoComposition: built.videoComposition,
        duration: built.duration + 5,
        keptRanges: built.keptRanges)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("f-\(UUID().uuidString).gif")
    defer { try? FileManager.default.removeItem(at: out) }

    await #expect(throws: (any Error).self) {
        try await GIFExporter.write(inflated, to: out, framesPerSecond: 5)
    }
}
