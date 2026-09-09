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
        audioMix: built.audioMix,
        renderTransform: built.renderTransform,
        naturalSize: built.naturalSize,
        duration: built.duration,
        sourceDuration: built.sourceDuration,
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
        audioMix: built.audioMix,
        renderTransform: built.renderTransform,
        naturalSize: built.naturalSize,
        duration: built.duration + 5,
        sourceDuration: built.sourceDuration,
        keptRanges: built.keptRanges)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("f-\(UUID().uuidString).gif")
    defer { try? FileManager.default.removeItem(at: out) }

    await #expect(throws: (any Error).self) {
        try await GIFExporter.write(inflated, to: out, framesPerSecond: 5)
    }
}

@Test("A throwing write leaves a previously-written good file at the same path untouched")
func throwingWriteDoesNotDestroyAPreviousGoodFile() async throws {
    // Guards finding #4 of the M3d fix wave: before the fix, `write` did
    // `try? removeItem(at: url)` up front and only produced bytes at
    // `finalize` — so a write that threw partway through (a per-frame
    // failure, a finalize failure) had already deleted whatever GOOD file a
    // previous, successful write left at that same path. In `exportMovie`'s
    // and `exportGIF`'s size ladders, that meant a rung that failed after an
    // earlier rung succeeded left the manifest describing a byte size and
    // dimensions for a path with no file on it at all — exactly the
    // scenario a reviewer proved by hand with a scratch test (a good 543
    // -byte GIF, then a throwing write leaving `fileExists == false`) but
    // could not trigger naturally through `MovieExporter`'s public API.
    // This test constructs the same shape directly against `GIFExporter`,
    // the actual site of the bug, rather than trying to thread it through
    // the ladder.
    let bundle = try await makeTestBundle(seconds: 1)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let out = FileManager.default.temporaryDirectory
        .appendingPathComponent("keep-\(UUID().uuidString).gif")
    defer { try? FileManager.default.removeItem(at: out) }

    // A good write first — this is the "previous successful rung".
    try await GIFExporter.write(built, to: out, framesPerSecond: 5)
    #expect(FileManager.default.fileExists(atPath: out.path))
    let goodSize = try #require(
        FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int)
    #expect(goodSize > 0)

    // Now a write to the SAME path that is guaranteed to throw — the
    // "failing later rung" — using the same inflated-duration trick as
    // `unfulfillableFrameFailsExport` above.
    let inflated = BuiltComposition(
        composition: built.composition,
        videoComposition: built.videoComposition,
        audioMix: built.audioMix,
        renderTransform: built.renderTransform,
        naturalSize: built.naturalSize,
        duration: built.duration + 5,
        sourceDuration: built.sourceDuration,
        keptRanges: built.keptRanges)
    await #expect(throws: (any Error).self) {
        try await GIFExporter.write(inflated, to: out, framesPerSecond: 5)
    }

    // The discriminating assertions: the file must still be there, and it
    // must still be the GOOD one — not deleted, and not partially
    // overwritten by whatever the throwing write got through before it
    // failed. Pre-fix, `fileExists` here was false.
    #expect(FileManager.default.fileExists(atPath: out.path),
            "a throwing write must not delete a previously-successful file at the same path")
    let sizeAfter = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int
    #expect(sizeAfter == goodSize,
            "the surviving file must be byte-for-byte the earlier good write, not a partial one")
}
