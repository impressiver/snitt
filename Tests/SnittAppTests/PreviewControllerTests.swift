import AVFoundation
import Foundation
import SnittApp
import SnittDocument
import SnittExport
import Testing

private func makeTestBundle(seconds: Double = 4) async throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds)
    return bundle
}

@MainActor
@Test("The controller attaches the composition it was given, not one it built")
func attachesTheGivenComposition() async throws {
    let bundle = try await makeTestBundle(seconds: 3)
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 0.5)

    let controller = PreviewController(built: built, jumpPoints: [])
    let item = try #require(controller.player.currentItem)

    // Identity, not equality. A controller that rebuilds its own composition
    // produces an equivalent-looking item and passes any assertion about
    // duration or size — this is the one that catches it.
    //
    // Deviation from the brief: `item.videoComposition ===
    // built.videoComposition` is asserted there too, but verified here to be
    // unwinnable by ANY correct implementation. `AVPlayerItem`'s
    // `videoComposition` setter takes an immutable snapshot of the mutable
    // composition it is given — the getter measurably returns a distinct
    // `AVVideoComposition` instance (not `AVMutableVideoComposition`), even
    // right after assignment in this same init. Asserting identity on the
    // readback would fail against attach-not-rebuild just as it fails against
    // rebuild, so it does not discriminate; the asset check above is the one
    // that does, since `CompositionBuilder.build` always returns a fresh
    // `AVMutableComposition` instance and only an attaching controller can
    // reuse `built.composition`'s.
    #expect(item.asset === built.composition)
    #expect(item.videoComposition?.renderSize == built.videoComposition.renderSize)
}

@MainActor
@Test("The player item becomes ready to play")
func itemBecomesReady() async throws {
    let bundle = try await makeTestBundle(seconds: 3)
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let controller = PreviewController(built: built, jumpPoints: [])
    let item = try #require(controller.player.currentItem)

    var waited = 0.0
    while item.status == AVPlayerItem.Status.unknown && waited < 8.0 {
        try await Task.sleep(nanoseconds: 50_000_000); waited += 0.05
    }
    // Spike S6 measured ~0.1s. A composition the player rejects fails here
    // rather than silently showing a black frame.
    #expect(item.status == AVPlayerItem.Status.readyToPlay)
    #expect(item.error == nil)
}

@MainActor
@Test("Seeking lands exactly, not at the nearest keyframe")
func seekIsExact() async throws {
    let bundle = try await makeTestBundle(seconds: 4)
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let controller = PreviewController(built: built, jumpPoints: [])

    await controller.seek(toSeconds: 2.5)

    // AVPlayer.seek(to:) without explicit tolerances snaps to a keyframe,
    // which on a 4-second clip can be a whole second away. This is the
    // discriminating assertion in principle.
    //
    // Verified finding (Step 5): on this toolchain/OS, `currentTime()`
    // reports the requested seek target rather than the actually-decoded
    // frame's timestamp, for BOTH the exact and tolerant overloads, and for
    // both a plain `AVURLAsset` item and a composition item. Explicitly
    // mutating `seek` to pass `.positiveInfinity`/`.positiveInfinity`
    // tolerances still lands this assertion at 2.5 — the test does not
    // discriminate in this environment. `toleranceBefore: .zero,
    // toleranceAfter: .zero` is kept anyway because it is the behavior Apple
    // documents and the one spike S6 and this task's brief specify; this
    // assertion is left in place as a duration/seek-completes regression
    // check, not as proof the tolerance argument is honored.
    let landed = CMTimeGetSeconds(controller.player.currentTime())
    #expect(abs(landed - 2.5) < 0.05)
}

@MainActor
@Test("Jumping to a marker seeks to its preview time")
func jumpSeeksToMarkerTime() async throws {
    let bundle = try await makeTestBundle(seconds: 4)
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let point = JumpPoint(timeSeconds: 1.75, label: "here")
    let controller = PreviewController(built: built, jumpPoints: [point])

    await controller.jump(to: point)

    // Same caveat as `seekIsExact`: `currentTime()` doesn't discriminate
    // tolerant vs. exact seeking in this environment. Left as a
    // jump-reaches-the-marker-time regression check.
    #expect(abs(CMTimeGetSeconds(controller.player.currentTime()) - 1.75) < 0.05)
}
