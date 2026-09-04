import AVFoundation
import Foundation
import SnittDocument

/// The composition and video composition built from a bundle plus its EDL.
///
/// `@unchecked Sendable`: the invariant this relies on is that `build(...)`
/// hands back objects it has finished mutating and never touches again — no
/// other reference to `composition` or `videoComposition` exists once this
/// value is returned, so there is no concurrent mutation for the compiler to
/// worry about even though `AVMutableComposition` and
/// `AVMutableVideoComposition` are not themselves `Sendable`. Callers that
/// hand the same `BuiltComposition` to multiple tasks and mutate it from more
/// than one of them would violate that invariant; nothing here does.
public struct BuiltComposition: @unchecked Sendable {
    public let composition: AVMutableComposition
    /// §9's explicit passthrough slot. Shipping overlays means giving THIS
    /// object a `customVideoCompositorClass` — nothing else changes.
    public let videoComposition: AVMutableVideoComposition
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

    public static func build(bundle: SnittBundle,
                             edl: EditDecisionList,
                             scale: Double) async throws -> BuiltComposition {
        let asset = AVURLAsset(url: bundle.captureURL)
        let assetDuration = CMTimeGetSeconds(try await asset.load(.duration))

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

        return BuiltComposition(composition: composition,
                                videoComposition: videoComposition,
                                duration: CMTimeGetSeconds(cursor),
                                keptRanges: kept)
    }
}
