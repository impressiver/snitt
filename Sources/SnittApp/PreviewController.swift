import AVFoundation
import Foundation
import SnittDocument
import SnittExport

/// Owns playback for the editor's preview.
///
/// `@MainActor` by necessity, not preference: `AVPlayerItem.init(asset:)` is
/// main-actor isolated under Swift 6 and `AVAudioMix` is non-Sendable
/// (spike S6).
///
/// This type ATTACHES a `BuiltComposition`. It never builds one. §9 makes the
/// shared builder load-bearing — "the most common serious bug class in video
/// editors is an export that does not match the preview" — and a preview that
/// constructs its own composition, video composition or audio mix is how that
/// guarantee is lost, one small tweak at a time.
@MainActor
public final class PreviewController {
    public private(set) var jumpPoints: [JumpPoint]
    public private(set) var durationSeconds: Double
    private var item: AVPlayerItem
    public let player: AVPlayer

    /// The bundle and scale this controller was built with. `apply` needs
    /// both to call `CompositionBuilder.build` again — the controller has no
    /// other source for them, since `BuiltComposition` itself doesn't carry
    /// them back out.
    private let bundle: SnittBundle
    private let scale: Double

    public init(built: BuiltComposition, jumpPoints: [JumpPoint],
                bundle: SnittBundle, scale: Double) {
        self.jumpPoints = jumpPoints
        self.durationSeconds = built.duration
        self.bundle = bundle
        self.scale = scale
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        self.item = item
        self.player = AVPlayer(playerItem: item)
    }

    public func play() { player.play() }
    public func pause() { player.pause() }

    /// Rebuilds the composition through `CompositionBuilder.build` — never
    /// by mutating the existing `AVMutableComposition` in place — and
    /// re-attaches it, keeping `jumpPoints` in step with the new
    /// `keptRanges`. §9: preview and export must stay the same code path.
    ///
    /// R2 (binding): `events` defaults to `[]`. That default means "this
    /// caller has no markers to place" — NOT "leave the old markers where
    /// they were." Recomputing against `[]` clears `jumpPoints` to `[]`
    /// rather than keeping stale positions from before the edit, because
    /// stale positions are the exact preview/export divergence §9 exists to
    /// prevent: a caller that forgets to pass events gets an empty scrub bar
    /// (visibly wrong, immediately noticed) rather than markers silently
    /// pointing at the wrong instant (wrong in a way nothing surfaces).
    /// Task 6, which owns the real event log, must pass its events
    /// explicitly.
    public func apply(edl: EditDecisionList, events: [LoggedEvent] = []) async throws {
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: scale)
        let newItem = AVPlayerItem(asset: built.composition)
        newItem.videoComposition = built.videoComposition
        newItem.audioMix = built.audioMix

        player.replaceCurrentItem(with: newItem)
        self.item = newItem
        self.durationSeconds = built.duration
        self.jumpPoints = MarkerJumpPoints.compute(events: events, keptRanges: built.keptRanges)
    }

    /// Exact seeking. `seek(to:)` without tolerances snaps to the nearest
    /// keyframe, which puts a marker jump seconds from the marker.
    public func seek(toSeconds seconds: Double) async {
        let clamped = max(0, min(seconds, durationSeconds))
        await player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                          toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func jump(to point: JumpPoint) async {
        await seek(toSeconds: point.timeSeconds)
    }
}
