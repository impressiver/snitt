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
    /// The SOURCE recording's media duration — `mediaDuration(of:)`'s
    /// result, before any cuts. Distinct from `duration` above, which is
    /// what this composition actually plays: the editor timeline builds its
    /// `Timebase` from this value plus `edl.cuts` (both source time) and
    /// draws — and interprets every gesture — on the OUTPUT axis that
    /// `Timebase` derives. Carried here so a caller building a second
    /// composition after a trim (`PreviewController.apply`) can keep the
    /// timeline's clocks in step without loading the asset a second time.
    ///
    /// This comment used to claim "the timeline view's axis is this clock",
    /// citing M4b whole-branch review Critical finding #1. It was true of a
    /// design the M5f whole-branch review removed, having measured that it
    /// reproduced that very finding — see `TimelineView.time(for:)`.
    public let sourceDuration: Double
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
    /// The recording's own pixel dimensions, before any crop or scale.
    ///
    /// Beside `mediaDuration` for the same reason: a caller reasoning about
    /// what an export will look like needs the source's shape, and reading it
    /// here keeps that read in the one place that already knows how this
    /// bundle's video track is found.
    public static func naturalVideoSize(of bundle: SnittBundle) async throws -> CGSize {
        let asset = AVURLAsset(url: bundle.captureURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return .zero
        }
        return try await track.load(.naturalSize)
    }

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
    /// `trackStates` are matched to composition audio tracks BY NAME, via
    /// `AudioTrackOrder.canonical`: composition audio track `i` is resolved
    /// to `canonical[i]`, and the state whose `track` equals that name (if
    /// any) governs it. A state naming something not in `canonical` —
    /// `"video"`, or a name from a stale EDL — matches nothing and is
    /// ignored, rather than being applied to whatever composition track
    /// happens to sit at its position.
    ///
    /// Task 1 matched by index instead, on the false assumption that
    /// `trackStates`' order already lined up with the composition's audio
    /// track order. It doesn't: `EditDecisionList.fullRange()` produces
    /// `["video", "microphone", "systemAudio"]`, but `AssetWriterSink` writes
    /// audio tracks in the order `[systemAudio, microphone]` (video is not
    /// audio). Index-matching therefore gave audio track 0 (systemAudio) the
    /// state named `"video"`, and dropped `"systemAudio"` off the end —
    /// muting system audio did nothing, and muting "video" silenced it. See
    /// task-1b-report.md for the full finding; name matching against the
    /// shared `AudioTrackOrder.canonical` is the fix.
    private static func audioMix(for tracks: [AVMutableCompositionTrack],
                                 states: [TrackState]) -> AVAudioMix? {
        guard !tracks.isEmpty else { return nil }
        // NOT `Dictionary(uniqueKeysWithValues:)`: that TRAPS on a repeated
        // key, so an `edit.json` naming the same track twice — hand-edited,
        // merged badly, or corrupted — would crash the app rather than
        // export. Last one wins, matching how a later line in a config file
        // normally overrides an earlier one.
        let statesByName = Dictionary(states.map { ($0.track, $0) },
                                      uniquingKeysWith: { _, last in last })
        let matchedStates: [TrackState?] = tracks.indices.map { index in
            guard index < AudioTrackOrder.canonical.count else { return nil }
            return statesByName[AudioTrackOrder.canonical[index]]
        }
        let needsMix = matchedStates.contains { $0.map { $0.muted || $0.gain != 1.0 } ?? false }
        guard needsMix else { return nil }

        let mix = AVMutableAudioMix()
        mix.inputParameters = zip(tracks, matchedStates).map { track, state in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            // Clamped to `0...1`, not passed through raw. `TrackState.gain`
            // is a plain `Double` decoded straight from `edit.json` — a
            // human hand-editing that sidecar (or a bad merge, or a stale
            // tool writing a different range) can put anything in it, and
            // `AVMutableAudioMixInputParameters.setVolume` documents no
            // clamping of its own. This milestone's ledger already has two
            // "it's latent, nothing writes it yet" calls that turned out
            // wrong — a deferred hazard came back as a SIGSEGV that silently
            // truncated suite runs, and a deferred track-naming bug would
            // have made muting system audio a silent no-op — so this is
            // fixed here, where the value is actually consumed, rather than
            // deferred to M4b's mute/gain UI. `TrackState.gain` itself stays
            // an unclamped `Double` and the EDL is never rejected: a
            // recording should still open with a strange sidecar.
            let rawVolume = state.map { $0.muted ? 0.0 : Float($0.gain) } ?? 1.0
            // `isFinite` FIRST, because min/max cannot clamp a NaN: every
            // comparison with NaN is false, so `min(max(.nan, 0), 1)` is
            // still NaN, and `setVolume` accepts it silently — verified,
            // `getVolumeRamp` reads it back with ok=true. A NaN volume is
            // undefined playback rather than a crash, which is the worst
            // shape: silent corruption nothing reports. `gain: null` decodes
            // to NaN from a hand-edited sidecar easily enough.
            let volume = rawVolume.isFinite ? min(max(rawVolume, 0.0), 1.0) : 1.0
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

        let kept = KeptRanges.compute(duration: assetDuration, cuts: edl.cuts.map(\.range))
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
        // Crop is a view onto the source, applied as a translation plus a
        // smaller `renderSize` — NOT a custom compositor and NOT
        // `AVVideoCompositionCoreAnimationTool` (§9, as narrowed): a geometric
        // transform on a layer instruction applies identically in
        // `AVPlayerItem` playback and `AVAssetExportSession` export, so the
        // editor previews a crop live and §9's one-builder guarantee holds
        // without an exception.
        //
        // `crop` is normalized, `scale` is a multiplier, and they commute —
        // the render is (crop × natural × scale) either way.
        let crop = (edl.crop?.isFullFrame == false && edl.crop?.isEmpty == false) ? edl.crop : nil
        let cropOrigin = CGPoint(x: (crop?.x ?? 0) * naturalSize.width,
                                 y: (crop?.y ?? 0) * naturalSize.height)
        let croppedSize = CGSize(width: (crop?.width ?? 1) * naturalSize.width,
                                 height: (crop?.height ?? 1) * naturalSize.height)

        let renderSize = CGSize(width: (croppedSize.width * scale).rounded(),
                                height: (croppedSize.height * scale).rounded())

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = compositionFrameDuration

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        // Passthrough plus scale. Still passthrough in §9's sense — there is no
        // custom compositor class — but expressed as a real instruction rather
        // than a nil, so overlays attach here later.
        // Order matters and reads left-to-right: orient the source, slide the
        // crop's top-left corner to the render origin, then scale. Because
        // `concatenating` applies the receiver first, the translation is
        // expressed in post-orientation pixels and is itself scaled — which is
        // what makes `renderSize` above the exact bounds of the result.
        layer.setTransform(
            preferredTransform
                .concatenating(CGAffineTransform(translationX: -cropOrigin.x, y: -cropOrigin.y))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale)),
            at: .zero)
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]

        let mix = audioMix(for: audioTrackPairs.map(\.destination), states: edl.trackStates)

        return BuiltComposition(composition: composition,
                                videoComposition: videoComposition,
                                audioMix: mix,
                                duration: CMTimeGetSeconds(cursor),
                                sourceDuration: assetDuration,
                                keptRanges: kept)
    }
}
