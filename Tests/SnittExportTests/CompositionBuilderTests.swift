import Testing
import AVFoundation
import Foundation
@testable import SnittExport
import SnittDocument

/// A tiny real movie, so the builder is exercised against AVFoundation rather
/// than a mock that cannot disagree with it.
private func makeTestBundle(seconds: Double = 4, audioTrackCount: Int = 0,
                            audioContent: SyntheticAudioContent = .silent) async throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds,
                                 audioTrackCount: audioTrackCount, audioContent: audioContent)
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
    edl.cuts = [Cut(range: TimeRange(start: 0, end: 2))]
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
    edl.cuts = [Cut(range: TimeRange(start: 0, end: 4))]
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
    edl.cuts = [Cut(range: TimeRange(start: 0, end: 3.9999995))]
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

@Test("A muted track gets a zero-volume mix parameter")
func mutedTrackIsSilencedInTheMix() async throws {
    let bundle = try await makeTestBundle(seconds: 2, audioTrackCount: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var edl = EditDecisionList()
    // AudioTrackOrder.canonical is [systemAudio, microphone], so
    // "systemAudio" is composition audio track 0 — the one asserted on
    // below. Naming these "audio0"/"audio1" (Task 1's fixture) would match
    // nothing under name-based matching and produce no mix at all.
    edl.trackStates = [TrackState(track: "systemAudio", muted: true, gain: 1.0),
                       TrackState(track: "microphone", muted: false, gain: 1.0)]

    let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)

    let mix = try #require(built.audioMix)
    #expect(mix.inputParameters.count == 2)
    // Discriminating: an implementation that builds a mix but never reads
    // `muted` produces two parameters at full volume and passes a
    // count-only assertion.
    let audioTracks = built.composition.tracks(withMediaType: AVMediaType.audio)
    let mutedID = audioTracks[0].trackID
    let mutedParams = try #require(mix.inputParameters.first { $0.trackID == mutedID })
    var volume: Float = -1
    #expect(mutedParams.getVolumeRamp(for: .zero, startVolume: &volume,
                                      endVolume: nil, timeRange: nil))
    #expect(volume == 0.0)
}

@Test("Gain is carried into the mix")
func gainIsCarriedIntoTheMix() async throws {
    let bundle = try await makeTestBundle(seconds: 2, audioTrackCount: 1)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var edl = EditDecisionList()
    edl.trackStates = [TrackState(track: "systemAudio", muted: false, gain: 0.25)]

    let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)

    let mix = try #require(built.audioMix)
    let params = try #require(mix.inputParameters.first)
    var volume: Float = -1
    #expect(params.getVolumeRamp(for: .zero, startVolume: &volume,
                                 endVolume: nil, timeRange: nil))
    // Discriminating against an implementation that honours `muted` but
    // ignores `gain` — it would report 1.0 here and pass the muted test.
    #expect(abs(volume - 0.25) < 0.001)
}

@Test("A negative gain from a hand-edited edit.json is clamped to silence, not passed through raw")
func negativeGainIsClampedToZero() async throws {
    // Finding #4 of the M4a review: `TrackState.gain` is a plain `Double`
    // decoded straight from `edit.json`, with nothing rejecting a
    // hand-edited or corrupted sidecar. `AVMutableAudioMixInputParameters
    // .setVolume` does not document clamping its input, so a negative gain
    // passed through raw is undefined rather than silenced. Discriminating
    // against a raw pass-through: an unclamped implementation would hand
    // AVFoundation -0.5 here, whatever that resolves to (not 0.0).
    let bundle = try await makeTestBundle(seconds: 2, audioTrackCount: 1)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var edl = EditDecisionList()
    edl.trackStates = [TrackState(track: "systemAudio", muted: false, gain: -0.5)]

    let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)

    let mix = try #require(built.audioMix)
    let params = try #require(mix.inputParameters.first)
    var volume: Float = -1
    #expect(params.getVolumeRamp(for: .zero, startVolume: &volume,
                                 endVolume: nil, timeRange: nil))
    #expect(volume == 0.0)
}

@Test("A gain greater than 1 from a hand-edited edit.json is clamped to unity, not amplified")
func excessiveGainIsClampedToOne() async throws {
    // Same finding as `negativeGainIsClampedToZero`, the other side of the
    // clamp. Discriminating against a raw pass-through: an unclamped
    // implementation would report 2.5 here, not 1.0.
    let bundle = try await makeTestBundle(seconds: 2, audioTrackCount: 1)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var edl = EditDecisionList()
    edl.trackStates = [TrackState(track: "systemAudio", muted: false, gain: 2.5)]

    let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)

    let mix = try #require(built.audioMix)
    let params = try #require(mix.inputParameters.first)
    var volume: Float = -1
    #expect(params.getVolumeRamp(for: .zero, startVolume: &volume,
                                 endVolume: nil, timeRange: nil))
    #expect(volume == 1.0)
}

@Test("A non-finite gain falls back to unity rather than becoming a NaN volume")
func nonFiniteGainFallsBackToUnity() async throws {
    // min/max CANNOT clamp NaN — every comparison with NaN is false, so
    // `min(max(.nan, 0), 1)` is still NaN, and setVolume takes it without
    // complaint. The result is undefined playback volume that nothing
    // reports: no crash, no error, just audio that may or may not exist.
    // The negative and >1 cases are caught by the ordinary clamp; this one
    // slips straight through it.
    let bundle = try await makeTestBundle(seconds: 2, audioTrackCount: 2)
    var edl = EditDecisionList.fullRange()
    edl.trackStates = [
        TrackState(track: "systemAudio", muted: false, gain: Double.nan),
        TrackState(track: "microphone", muted: true, gain: 1.0),
    ]

    let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)

    let mix = try #require(built.audioMix)
    let tracks = built.composition.tracks(withMediaType: AVMediaType.audio)
    let params = try #require(mix.inputParameters.first { $0.trackID == tracks[0].trackID })
    var volume: Float = -1
    #expect(params.getVolumeRamp(for: .zero, startVolume: &volume,
                                 endVolume: nil, timeRange: nil))
    #expect(volume.isFinite)
    #expect(volume == 1.0)
}

@Test("A duplicate track name in the EDL does not crash the export")
func duplicateTrackNameIsSurvivable() async throws {
    // `Dictionary(uniqueKeysWithValues:)` TRAPS on a repeated key — signal 5,
    // the whole process — and an edit.json is a plain file a human can edit
    // or a bad merge can duplicate. Refusing to export would be defensible;
    // crashing is not. Last one wins.
    let bundle = try await makeTestBundle(seconds: 2, audioTrackCount: 2)
    var edl = EditDecisionList.fullRange()
    edl.trackStates = [
        TrackState(track: "systemAudio", muted: false, gain: 1.0),
        TrackState(track: "systemAudio", muted: true, gain: 1.0),
        TrackState(track: "microphone", muted: false, gain: 1.0),
    ]

    let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)

    let mix = try #require(built.audioMix)
    let tracks = built.composition.tracks(withMediaType: AVMediaType.audio)
    let params = try #require(mix.inputParameters.first { $0.trackID == tracks[0].trackID })
    var volume: Float = -1
    #expect(params.getVolumeRamp(for: .zero, startVolume: &volume,
                                 endVolume: nil, timeRange: nil))
    #expect(volume == 0.0)
}

@Test("A recording with no audio produces no mix at all")
func noAudioMeansNoMix() async throws {
    let bundle = try await makeTestBundle(seconds: 2, audioTrackCount: 0)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    let built = try await CompositionBuilder.build(
        bundle: bundle, edl: EditDecisionList(), scale: 1.0)
    // An empty AVAudioMix attached to a player item is not the same as no
    // mix; nil states plainly that there is nothing to apply.
    #expect(built.audioMix == nil)
}

@Test("Muting a track changes the exported file, not just the preview")
func exportAppliesTheMix() async throws {
    // §9's actual claim. An implementation that puts the mix on the player
    // item only — the obvious shortcut — passes every test above and fails
    // this one, because the exported audio would be unchanged.
    // `.tone`, deliberately, not the default `.silent`: an already-silent
    // source encodes to the same size whether or not the mix is applied at
    // all, so this test cannot discriminate a correct implementation from
    // one that ignores the mix entirely unless there is real signal to mute.
    let bundle = try await makeTestBundle(seconds: 2, audioTrackCount: 1, audioContent: .tone)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var muted = EditDecisionList()
    muted.trackStates = [TrackState(track: "systemAudio", muted: true, gain: 1.0)]

    let loudOut = FileManager.default.temporaryDirectory
        .appendingPathComponent("loud-\(UUID().uuidString).mp4")
    let quietOut = FileManager.default.temporaryDirectory
        .appendingPathComponent("quiet-\(UUID().uuidString).mp4")
    defer {
        try? FileManager.default.removeItem(at: loudOut)
        try? FileManager.default.removeItem(at: quietOut)
    }

    _ = try await MovieExporter.export(bundle: bundle, edl: EditDecisionList(),
                                       scale: 1.0, to: loudOut)
    _ = try await MovieExporter.export(bundle: bundle, edl: muted,
                                       scale: 1.0, to: quietOut)

    // Silence encodes smaller than signal. Relative, not an absolute
    // threshold — the encoder is not deterministic under load (M3d).
    let loud = try #require(FileManager.default
        .attributesOfItem(atPath: loudOut.path)[.size] as? Int)
    let quiet = try #require(FileManager.default
        .attributesOfItem(atPath: quietOut.path)[.size] as? Int)
    #expect(quiet < loud,
            "muting a track must change the exported bytes, not only the preview")
}

@Test("Track states are matched by name, so system audio mutes system audio")
func systemAudioStateMutesSystemAudio() async throws {
    let bundle = try await makeTestBundle(seconds: 2, audioTrackCount: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var edl = EditDecisionList.fullRange()
    edl.trackStates = edl.trackStates.map {
        $0.track == "systemAudio" ? TrackState(track: "systemAudio", muted: true, gain: 1.0) : $0
    }

    let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)

    let mix = try #require(built.audioMix)
    let tracks = built.composition.tracks(withMediaType: AVMediaType.audio)
    // AudioTrackOrder.canonical is [systemAudio, microphone], so index 0 is
    // the one that must be silenced. Index-matching against fullRange()
    // silences this track for the state named "video" instead, and leaves
    // this assertion reading 1.0.
    let params = try #require(mix.inputParameters.first { $0.trackID == tracks[0].trackID })
    var volume: Float = -1
    #expect(params.getVolumeRamp(for: .zero, startVolume: &volume,
                                 endVolume: nil, timeRange: nil))
    #expect(volume == 0.0)
}

@Test("A state naming the video track never silences audio")
func videoStateDoesNotSilenceAudio() async throws {
    let bundle = try await makeTestBundle(seconds: 2, audioTrackCount: 2)
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    var edl = EditDecisionList.fullRange()
    edl.trackStates = edl.trackStates.map {
        $0.track == "video" ? TrackState(track: "video", muted: true, gain: 1.0) : $0
    }

    let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)

    // "video" is not an audio track. Muting it must be a no-op for audio,
    // not a mute of whichever audio track happens to sit at index 0.
    // This is the exact bug positional matching produces.
    #expect(built.audioMix == nil)
}
