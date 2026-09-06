import AVFoundation
import Foundation
import SnittApp
import SnittDocument
import SnittExport
import Testing

private func makeTestBundle(seconds: Double = 4,
                             maxKeyFrameInterval: Int32? = nil,
                             audioTrackCount: Int = 0) async throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds,
                                  maxKeyFrameInterval: maxKeyFrameInterval,
                                  audioTrackCount: audioTrackCount)
    return bundle
}

/// Frame rate `writeSyntheticMovie`'s default (`fps: Int32 = 30`) uses, kept
/// here so the sparse-keyframe interval below can be expressed as "the whole
/// clip" without hardcoding 30 a second time.
private let syntheticMovieFPS: Int32 = 30

@MainActor
@Test("The controller attaches the composition it was given, not one it built")
func attachesTheGivenComposition() async throws {
    let bundle = try await makeTestBundle(seconds: 3, audioTrackCount: 1)
    // A muted track, so `built.audioMix` is non-nil (finding #1 of the M4a
    // review): `AVAudioMix` is nil whenever nothing is muted and no gain
    // differs from 1.0, and `nil === nil` would pass this assertion
    // vacuously even against an implementation that drops the assignment
    // entirely.
    var edl = EditDecisionList()
    edl.trackStates = [TrackState(track: "systemAudio", muted: true, gain: 1.0)]
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: edl, scale: 0.5)

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
    // Finding #1 of the M4a review: `attachesTheGivenComposition` checked
    // asset identity and render size but said nothing about `audioMix`, so a
    // refactor dropping `item.audioMix = built.audioMix` in
    // `PreviewController.init` left all 376 tests passing while silently
    // un-muting the preview (export stays muted — §9's exact divergence).
    //
    // Deviation from the brief: identity on the READBACK (`item.audioMix
    // === built.audioMix`) is unwinnable by any correct implementation, for
    // the same reason `item.videoComposition === built.videoComposition` is
    // above — measured here, not assumed: `AVPlayerItem`'s `audioMix` setter
    // takes an immutable snapshot of whatever `AVAudioMix` it is handed, so
    // the getter returns a distinct instance even right after assignment in
    // this same init (confirmed by printing both objects' addresses). So
    // this checks that the READ-BACK mix carries the same volume, for the
    // same track, that `built.audioMix` does — which a controller that
    // drops the assignment (leaving `item.audioMix` nil) fails outright, and
    // one that reuses `built.audioMix` (however AVFoundation snapshots it)
    // passes.
    let mix = try #require(built.audioMix, "the fixture's muted track should produce a real mix")
    let expectedParams = try #require(mix.inputParameters.first)
    let attachedMix = try #require(item.audioMix)
    let attachedParams = try #require(
        attachedMix.inputParameters.first { $0.trackID == expectedParams.trackID })
    var expectedVolume: Float = -1
    var attachedVolume: Float = -1
    #expect(expectedParams.getVolumeRamp(for: .zero, startVolume: &expectedVolume,
                                         endVolume: nil, timeRange: nil))
    #expect(attachedParams.getVolumeRamp(for: .zero, startVolume: &attachedVolume,
                                         endVolume: nil, timeRange: nil))
    #expect(attachedVolume == expectedVolume)
    #expect(attachedVolume == 0.0, "the fixture muted this track; the attached mix should reflect that")
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
    // The original fixture (default `maxKeyFrameInterval`) was suspected to
    // encode with effectively every frame as a keyframe, leaving a tolerant
    // seek nothing to snap to. `maxKeyFrameInterval` set to the whole clip's
    // frame count (forcing as few keyframes as VideoToolbox will allow) is
    // used here on that theory.
    //
    // Measured, not just theorized: it does NOT fix the underlying
    // indistinguishability. Directly counting sync samples (via
    // AVAssetReader) shows this fixture still encodes 6 keyframes over ~124
    // frames with `maxKeyFrameInterval` set to 120 vs. 9 keyframes with it
    // unset — `AVVideoMaxKeyFrameIntervalKey` is a upper bound VideoToolbox
    // does not fill up to for this low-motion content, so "one keyframe at
    // the start" was never achieved. More importantly, even granting that,
    // re-running Task 3's mutation test (temporarily dropping
    // `toleranceBefore/After` from `PreviewController.seek` and rebuilding)
    // against THIS sparser fixture still lands `currentTime()` at exactly
    // 2.5 after a request for 2.5 seconds — the same non-discriminating
    // result Task 3 found with the original fixture. So the diagnosis that
    // "the fixture is too keyframe-dense to observe" was incomplete/wrong:
    // on this toolchain (Swift 6.3.3 / macOS 26), `AVPlayer.currentTime()`
    // after a completed seek reports the requested target time regardless of
    // tolerance and regardless of keyframe density, not the actually-decoded
    // sync sample's timestamp. This assertion remains a
    // duration/seek-completes regression check, not proof the tolerance
    // argument changes anything observable via `currentTime()` here — see
    // `synthetic-fixes-report.md` for the numbers.
    let seconds = 4.0
    let bundle = try await makeTestBundle(
        seconds: seconds, maxKeyFrameInterval: Int32((seconds * Double(syntheticMovieFPS)).rounded()))
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let controller = PreviewController(built: built, jumpPoints: [])

    await controller.seek(toSeconds: 2.5)

    let landed = CMTimeGetSeconds(controller.player.currentTime())
    #expect(abs(landed - 2.5) < 0.05)
}

@MainActor
@Test("Jumping to a marker seeks to its preview time")
func jumpSeeksToMarkerTime() async throws {
    // Same sparse-keyframe fixture as `seekIsExact`, and the same caveat: see
    // that test's comment. Measured with the tolerance arguments dropped
    // from `PreviewController.seek` against this sparser fixture,
    // `currentTime()` still lands at exactly 1.75 after jumping to a 1.75s
    // marker — this does not discriminate here either. Left as a
    // jump-reaches-the-marker-time regression check.
    let seconds = 4.0
    let bundle = try await makeTestBundle(
        seconds: seconds, maxKeyFrameInterval: Int32((seconds * Double(syntheticMovieFPS)).rounded()))
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    let point = JumpPoint(timeSeconds: 1.75, label: "here")
    let controller = PreviewController(built: built, jumpPoints: [point])

    await controller.jump(to: point)

    #expect(abs(CMTimeGetSeconds(controller.player.currentTime()) - 1.75) < 0.05)
}
