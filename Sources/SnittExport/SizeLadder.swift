import Foundation

/// The bounded sequence of quality settings GIF size targeting walks.
///
/// ImageIO has no `fileLengthLimit` equivalent, so hitting a byte target for
/// a GIF means encoding, measuring, and trying again with less. Frame rate
/// drops first: a GIF's size is roughly linear in frame count, and 10fps
/// reads as fine where half resolution is immediately visible.
///
/// Bounded on purpose. Each rung is a full re-encode.
///
/// Deliberately a separate type from `MovieExporter`'s private mp4
/// `sizeLadder` (scale-only, because `fileLengthLimit` handles bitrate for
/// mp4): GIF has no bitrate primitive at all, so this ladder is the entire
/// size-targeting mechanism, walking two axes (fps, then scale) rather than
/// one. Unifying the two would carry a dead axis for each caller.
public struct SizeLadder {
    public struct Rung: Equatable, Sendable {
        public let framesPerSecond: Double
        public let scaleMultiplier: Double
    }

    public static func rungs(baseFPS: Double) -> [Rung] {
        let fpsSteps = [15.0, 10.0, 8.0, 5.0].filter { $0 <= baseFPS }
        let ladderFPS = fpsSteps.isEmpty ? [baseFPS] : fpsSteps
        var rungs: [Rung] = ladderFPS.map { Rung(framesPerSecond: $0, scaleMultiplier: 1.0) }
        // Only once frame rate is exhausted does resolution drop, and both
        // rungs keep the lowest frame rate so each is strictly worse.
        let slowest = ladderFPS.last ?? baseFPS
        rungs.append(Rung(framesPerSecond: slowest, scaleMultiplier: 0.6))
        rungs.append(Rung(framesPerSecond: slowest, scaleMultiplier: 0.4))
        return rungs
    }
}
