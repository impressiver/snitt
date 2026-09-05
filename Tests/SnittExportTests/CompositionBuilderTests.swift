import Testing
import AVFoundation
import Foundation
@testable import SnittExport
import SnittDocument

/// A tiny real movie, so the builder is exercised against AVFoundation rather
/// than a mock that cannot disagree with it.
private func makeTestBundle(seconds: Double = 4, audioTrackCount: Int = 0) async throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds, audioTrackCount: audioTrackCount)
    return bundle
}

@Test("A composition with no cuts spans the whole recording")
func noCutsSpansEverything() async throws {
    let bundle = try await makeTestBundle(seconds: 4)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: .fullRange(), scale: 1.0)
    #expect(abs(built.duration - 4) < 0.2)
}

@Test("Cutting the head shortens the composition by that much")
func headCutShortens() async throws {
    let bundle = try await makeTestBundle(seconds: 4)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    var edl = EditDecisionList.fullRange()
    edl.cuts = [TimeRange(start: 0, end: 2)]
    let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
    #expect(abs(built.duration - 2) < 0.2)
}

@Test("The video composition is an explicit passthrough, never nil")
func videoCompositionIsExplicit() async throws {
    // §9: the passthrough slot must be a real object so that shipping overlays
    // means assigning a customVideoCompositorClass to it, not threading a new
    // argument through every call site.
    let bundle = try await makeTestBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: .fullRange(), scale: 1.0)
    #expect(built.videoComposition.renderSize.width > 0)
    #expect(built.videoComposition.instructions.isEmpty == false)
}

@Test("Scaling halves the render size but not the duration")
func scaleAffectsSizeNotTime() async throws {
    let bundle = try await makeTestBundle(seconds: 4)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let full = try await CompositionBuilder.build(
        bundle: bundle, edl: .fullRange(), scale: 1.0)
    let half = try await CompositionBuilder.build(
        bundle: bundle, edl: .fullRange(), scale: 0.5)

    #expect(abs(half.videoComposition.renderSize.width
                - full.videoComposition.renderSize.width / 2) < 2)
    #expect(abs(half.duration - full.duration) < 0.2)
}

@Test("Cutting everything is refused rather than exporting an empty movie")
func cuttingEverythingThrows() async throws {
    // An empty export is worse than an error: it succeeds, writes a file, and
    // the agent attaches nothing to a pull request.
    let bundle = try await makeTestBundle(seconds: 4)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    var edl = EditDecisionList.fullRange()
    edl.cuts = [TimeRange(start: 0, end: 4)]
    await #expect(throws: CompositionError.everythingCut) {
        _ = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
    }
}

@Test("A cut leaving only a sub-frame sliver throws rather than building a degenerate segment")
func sliverKeptRangeThrows() async throws {
    // Task 1's review: KeptRanges.compute is correct set subtraction, but a
    // cut ending a fraction of a frame before the recording's end leaves a
    // kept range too short to be a real segment. That filtering is this
    // builder's job (at its own frame duration, 1/60s), and when nothing
    // survives the filter this must throw everythingCut, not build a
    // composition with a degenerate segment in it.
    let bundle = try await makeTestBundle(seconds: 4)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    var edl = EditDecisionList.fullRange()
    // Leaves a kept range of ~0.0000005s — far below one frame at 1/60s.
    edl.cuts = [TimeRange(start: 0, end: 3.9999995)]
    await #expect(throws: CompositionError.everythingCut) {
        _ = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
    }
}

@Test("Each composition audio track carries only its own source track's samples")
func audioTracksPairBySourceNotFlattened() async throws {
    // Review finding: a video-only synthetic movie never exercises the
    // per-source-track audio pairing (sourceAudio == [] in every other test
    // here), so the pairing code has run only against a reviewer's throwaway
    // fixture, not the checked-in suite. This is that missing coverage.
    //
    // Matched by sourceTrackID via AVCompositionTrackSegment rather than by
    // content, so this also catches a pairing that is merely REVERSED (index
    // 0 gets source 1's samples and vice versa) as well as one that
    // flattens both sources into a single composition track.
    let bundle = try await makeTestBundle(seconds: 2, audioTrackCount: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let sourceAsset = AVURLAsset(url: bundle.captureURL)
    let sourceAudioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
    #expect(sourceAudioTracks.count == 2)

    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: .fullRange(), scale: 1.0)

    let compositionAudioTracks = built.composition.tracks(withMediaType: .audio)
    #expect(compositionAudioTracks.count == 2)

    for (index, compositionTrack) in compositionAudioTracks.enumerated() {
        let expectedSourceID = sourceAudioTracks[index].trackID
        let segmentSourceIDs = compositionTrack.segments.compactMap(\.sourceTrackID)
        #expect(!segmentSourceIDs.isEmpty)
        #expect(segmentSourceIDs.allSatisfy { $0 == expectedSourceID },
                "composition audio track \(index) should carry only source track \(expectedSourceID)'s samples, saw \(segmentSourceIDs)")
    }
}
