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
    public let jumpPoints: [JumpPoint]
    public let durationSeconds: Double
    private let item: AVPlayerItem
    public let player: AVPlayer

    public init(built: BuiltComposition, jumpPoints: [JumpPoint]) {
        self.jumpPoints = jumpPoints
        self.durationSeconds = built.duration
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        self.item = item
        self.player = AVPlayer(playerItem: item)
    }

    public func play() { player.play() }
    public func pause() { player.pause() }

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
