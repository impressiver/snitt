import AVFoundation
import Foundation
import SnittDocument

/// The composition and video composition built from a bundle plus its EDL.
///
/// `@unchecked Sendable`: the invariant this relies on is that `build(...)`
/// hands back objects it has finished mutating and never touches again — no
/// other reference to `composition`, `videoComposition`, or `audioMix`
/// exists once this value is returned, so there is no concurrent mutation
/// for the compiler to worry about even though `AVMutableComposition`,
/// `AVMutableVideoComposition`, and `AVAudioMix` are not themselves
/// `Sendable`. Callers that hand the same `BuiltComposition` to multiple
/// tasks and mutate it from more than one of them would violate that
/// invariant; nothing here does.
public struct BuiltComposition: @unchecked Sendable {
    public let composition: AVMutableComposition
    /// §9's explicit passthrough slot. Shipping overlays means giving THIS
    /// object a `customVideoCompositorClass` — nothing else changes.
    public let videoComposition: AVMutableVideoComposition
    /// The EDL's per-track mute and gain, expressed as an `AVAudioMix`. Nil
    /// when there is nothing to express — no audio tracks, or every track
    /// unmuted at unity gain — so preview and export can each check for nil
    /// rather than every caller re-deriving "is this mix actually a no-op."
    /// Built once, inside `build`, and never mutated afterwards: see the
    /// `@unchecked Sendable` note above.
    public let audioMix: AVAudioMix?
    public let duration: Double
    /// The kept ranges (source-recording time) this composition was built
    /// from — `KeptRanges.compute`'s output already filtered to drop
    /// sub-frame slivers, i.e. exactly what `build` inserted into
    /// `composition`. Carried here so a caller mapping something else in
    /// source time (marker timestamps, for instance) into export time uses
    /// the SAME set the composition used, rather than recomputing it against
    /// a separately-loaded asset and hoping the two never disagree.
    public let keptRanges: [TimeRange]
}

public enum CompositionError: Error, Equatable {
    case noVideoTrack
    /// Every frame was cut — or what survived was entirely sub-frame slivers
    /// (see `minimumKeptDuration` below). Refused rather than exported: an
    /// empty movie succeeds, writes a file, and tells the caller nothing is
    /// wrong.
    case everythingCut
}

/// Turns a bundle plus its EDL into the composition that both preview and
/// export use.
///
/// §9 makes this sharing binding: "the most common serious bug class in video
/// editors is an export that does not match the preview, and the only durable
/// defense is making the two literally the same code path." M4's preview
/// attaches the result to an `AVPlayerItem`; export hands it to an export
/// session. Neither builds its own.
///
/// `AVVideoCompositionCoreAnimationTool` is deliberately not used: it cannot
/// attach to an `AVPlayerItem` (V5), so it would force two overlay
/// implementations that can diverge.
public enum CompositionBuilder {
    /// The frame duration every `AVMutableVideoComposition` this builder
    /// produces is set to. Also the basis for `minimumKeptDuration` — the two
    /// used to be independent `1/60` literals that could drift apart, which
    /// defeats the point of the threshold (it is only meaningful as "one
    /// frame of THIS composition's frame duration").
    static let compositionFrameDuration = CMTime(value: 1, timescale: 60)

    /// `KeptRanges.compute` is pure set subtraction: a cut ending a
    /// microsecond before the recording's end leaves a kept range that short.
    /// That is correct arithmetic, but a range that short is a degenerate
    /// segment once inserted into an `AVMutableComposition`, not a real one.
    /// Filtering it out is export-layer policy, so it lives here rather than
    /// in `KeptRanges` — at one frame of `compositionFrameDuration`.
    static let minimumKeptDuration: Double = CMTimeGetSeconds(compositionFrameDuration)

    /// The MEDIA duration of `bundle.capture.mov`, loaded straight from the
    /// asset — never `RecordingMetadata.durationSeconds`, which is WALL time
    /// stamped around the capture and always longer (see that property's doc
    /// comment in `SnittDocument`).
    ///
    /// This is the SAME call `build(bundle:edl:scale:)` below makes for its
    /// own `assetDuration`. It is factored out, rather than left as two call
    /// sites that happen to agree, specifically so a caller outside this
    /// file — `AutomationHost.trim`, which computes `KeptRanges` and
    /// `TrimSummary` before any composition exists — runs on the exact same
    /// clock the export path does. Before this fix, trim used the wall clock
    /// and export used this one; the two disagree on every real recording,
    /// and an agent trimming `--start 1` on a 4.25s-wall/4.0s-media
    /// recording was told `keptSeconds` on a clock the exported file does
    /// not have.
    public static func mediaDuration(of bundle: SnittBundle) async throws -> Double {
        let asset = AVURLAsset(url: bundle.captureURL)
        return CMTimeGetSeconds(try await asset.load(.duration))
    }

    /// Builds the mix expressing the EDL's per-track mute and gain.
    ///
    /// Returns nil when there is nothing to express — no audio tracks, or
    /// every track unmuted at unity gain. A nil mix and an empty mix are not
    /// the same thing to a caller: nil says "nothing to apply".
    ///
    /// `trackStates` are matched to composition audio tracks BY INDEX, in the
    /// order the source declared them. A `TrackState` naming an index the
    /// recording does not have is ignored — it can only come from an EDL
    /// written against a different bundle, and refusing the whole export for
    /// it would strand a recording behind a stale sidecar.
    ///
    /// This is index matching, not name matching — `TrackState.track`'s
    /// string content plays no part in which composition track a state
    /// governs. That was checked against the recording path before landing:
    /// `EditDecisionList.fullRange()` currently produces three states
    /// (`"video"`, `"microphone"`, `"systemAudio"`, in that order), and
    /// `AssetWriterSink` writes audio tracks in the order `[systemAudio,
    /// microphone]`. Passed through unfiltered, those two orderings do NOT
    /// line up — `states[0]` is not audio at all, and `states[1]`/`states[2]`
    /// are reversed relative to the composition's actual audio track order.
    /// Fixing that is the producer's job (filtering `trackStates` down to the
    /// real audio tracks, in the composition's order, before it reaches
    /// `build`), not this function's: this function has no way to learn a
    /// composition audio track's semantic identity from the loaded
    /// `AVAssetTrack` alone, and hardcoding `"systemAudio"`/`"microphone"`
    /// here would only work for that one producer while breaking every
    /// caller (including this file's own tests) that uses its own track
    /// naming. See task-1-report.md for the full finding.
    private static func audioMix(for tracks: [AVMutableCompositionTrack],
                                 states: [TrackState]) -> AVAudioMix? {
        guard !tracks.isEmpty else { return nil }
        let needsMix = states.contains { $0.muted || $0.gain != 1.0 }
        guard needsMix else { return nil }

        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.enumerated().map { index, track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            let state = index < states.count ? states[index] : nil
            let volume = state.map { $0.muted ? 0.0 : Float($0.gain) } ?? 1.0
            parameters.setVolume(volume, at: .zero)
            return parameters
        }
        return mix
    }

    public static func build(bundle: SnittBundle,
                             edl: EditDecisionList,
                             scale: Double) async throws -> BuiltComposition {
        let asset = AVURLAsset(url: bundle.captureURL)
        let assetDuration = try await mediaDuration(of: bundle)

        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first
        else { throw CompositionError.noVideoTrack }
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio)

        let kept = KeptRanges.compute(duration: assetDuration, cuts: edl.cuts)
            .filter { $0.end - $0.start >= minimumKeptDuration }
        guard !kept.isEmpty else { throw CompositionError.everythingCut }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CompositionError.noVideoTrack }

        // One composition audio track per source track, so the EDL's per-track
        // mute and gain stay addressable in M4 rather than being flattened now.
        //
        // Paired at creation time — (source, destination) tuples built in one
        // pass — rather than building a `sourceAudio` array and an
        // `addMutableTrack` array separately and trusting their indices to
        // stay in lockstep. `compactMap` over the sources with `addMutableTrack`
        // discarded on nil used to do exactly that: if `addMutableTrack` ever
        // returned nil for a non-final track, the compacted array shortened
        // and every subsequent source track silently paired with the wrong
        // destination. Pairing here can't drift because there is only ever
        // one array to walk.
        var audioTrackPairs: [(source: AVAssetTrack, destination: AVMutableCompositionTrack)] = []
        for source in sourceAudio {
            guard let destination = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            audioTrackPairs.append((source, destination))
        }

        var cursor = CMTime.zero
        for range in kept {
            let timeRange = CMTimeRange(
                start: CMTime(seconds: range.start, preferredTimescale: 600),
                end: CMTime(seconds: range.end, preferredTimescale: 600))
            try videoTrack.insertTimeRange(timeRange, of: sourceVideo, at: cursor)
            for pair in audioTrackPairs {
                try pair.destination.insertTimeRange(timeRange, of: pair.source, at: cursor)
            }
            cursor = CMTimeAdd(cursor, timeRange.duration)
        }

        let naturalSize = try await sourceVideo.load(.naturalSize)
        let preferredTransform = try await sourceVideo.load(.preferredTransform)
        let renderSize = CGSize(width: (naturalSize.width * scale).rounded(),
                                height: (naturalSize.height * scale).rounded())

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = compositionFrameDuration

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        // Passthrough plus scale. Still passthrough in §9's sense — there is no
        // custom compositor class — but expressed as a real instruction rather
        // than a nil, so overlays attach here later.
        layer.setTransform(
            preferredTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale)),
            at: .zero)
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]

        let mix = audioMix(for: audioTrackPairs.map(\.destination), states: edl.trackStates)

        return BuiltComposition(composition: composition,
                                videoComposition: videoComposition,
                                audioMix: mix,
                                duration: CMTimeGetSeconds(cursor),
                                keptRanges: kept)
    }
}
