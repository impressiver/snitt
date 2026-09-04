import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SnittDocument
import UniformTypeIdentifiers

public enum GIFError: Error, Equatable {
    /// `AVAssetImageGenerator.videoComposition` raises an uncatchable ObjC
    /// exception when `renderSize` is not positive. This is thrown instead,
    /// before the assignment.
    case degenerateRenderSize
    case frameGenerationFailed(String)
    case destinationUnavailable
    case finalizeFailed
}

/// Writes a `BuiltComposition` as an animated GIF.
///
/// Reads the SAME composition mp4 export writes (§9). `AVAssetImageGenerator`
/// accepts a `videoComposition`, so the cuts, scale and transform applied here
/// are the ones `CompositionBuilder` decided — not a second derivation that
/// can drift from what the preview shows.
///
/// A GIF carries no audio. That is the format, not an omission, but callers
/// must say so rather than let a user discover a silent demo.
public enum GIFExporter {
    public static func write(_ built: BuiltComposition,
                             to url: URL,
                             framesPerSecond: Double) async throws {
        let renderSize = built.videoComposition.renderSize
        // MUST precede the assignment below. Not a defensive nicety: the
        // ObjC exception this avoids cannot be caught from Swift, so the
        // alternative to this guard is a dead process.
        guard renderSize.width > 0, renderSize.height > 0 else {
            throw GIFError.degenerateRenderSize
        }
        guard framesPerSecond > 0, built.duration > 0 else {
            throw GIFError.degenerateRenderSize
        }

        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Deliberately NOT `generator.maximumSize = renderSize`: setting
        // maximumSize independently downscales every generated CGImage to
        // fit that box, which produced 160x120 output for a 0.5 scale even
        // with the `videoComposition` assignment above deleted — masking
        // the exact bug §9 exists to catch (an encoder that reads frames
        // without applying the shared composition). Frame size must come
        // from `videoComposition.renderSize` alone, per Apple's documented
        // behaviour that a generator with a video composition assigned uses
        // that composition's render size. Verified: removing the
        // `videoComposition` assignment now correctly fails
        // `gifHonoursScale` with 320x240 instead of quietly passing.
        let interval = 1.0 / framesPerSecond
        // Index-based, not `while t < duration { t += interval }`: repeated
        // float addition of a non-exact binary fraction (0.2s at 5fps) drifts
        // low enough after ~10 additions that the loop admits one extra
        // frame at the boundary — measured as 11 frames for a 2s/5fps clip
        // that should produce exactly 10. Deriving each time from the frame
        // index avoids the accumulation entirely.
        let frameCount = Int(built.duration * framesPerSecond)
        guard frameCount > 0 else { throw GIFError.degenerateRenderSize }
        let times = (0..<frameCount).map {
            CMTime(seconds: Double($0) * interval, preferredTimescale: 600)
        }

        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, times.count, nil)
        else { throw GIFError.destinationUnavailable }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)

        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFUnclampedDelayTime: interval
            ]
        ] as CFDictionary

        for await result in generator.images(for: times) {
            switch result {
            case .success(requestedTime: _, image: let image, actualTime: _):
                CGImageDestinationAddImage(destination, image, frameProperties)
            case .failure(requestedTime: let time, error: let error):
                // Per-frame failures are DELIVERED, not thrown. Skipping them
                // writes a GIF that is quietly missing frames — §11 is
                // explicit that corrupt output is the worst outcome.
                throw GIFError.frameGenerationFailed(
                    "frame at \(CMTimeGetSeconds(time))s: \(error.localizedDescription)")
            @unknown default:
                throw GIFError.frameGenerationFailed("unknown result case")
            }
        }

        guard CGImageDestinationFinalize(destination) else {
            throw GIFError.finalizeFailed
        }
    }
}
