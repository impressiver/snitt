// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

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
    /// A same-directory sibling of `url`, used so the write lands atomically
    /// (finding #4): `CGImageDestination` only materialises bytes at
    /// `finalize`, so a rung that throws partway through — a per-frame
    /// failure, a finalize failure — must not touch whatever a PREVIOUS,
    /// successful rung already wrote to `url`. Writing here first and moving
    /// into place only after `finalize` succeeds means a throwing rung
    /// leaves the last good file exactly as it was, and the manifest is
    /// never built from a byte size that describes a path with no file.
    private static func temporaryURL(near url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".snitt-tmp-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
    }

    /// Composite the rings visible at this instant onto one decoded frame.
    ///
    /// Returns the original image untouched if a context cannot be made, so a
    /// drawing failure costs the overlay rather than the export.
    private static func drawClicks(_ marks: [ClickMark], on image: CGImage,
                                   atOutputTime outputTime: Double,
                                   renderSize: CGSize) -> CGImage {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // ClickMark positions have a TOP-LEFT origin; CGContext's is
        // bottom-left. Flipping here, once, keeps the mark type in one
        // convention rather than making every reader ask which it is.
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        ClickOverlay.draw(marks: marks, atOutputTime: outputTime,
                          renderSize: renderSize, into: context)
        return context.makeImage() ?? image
    }

    public static func write(_ built: BuiltComposition,
                             to url: URL,
                             framesPerSecond: Double,
                             clicks: [ClickMark] = [],
                             cues: [SubtitleCue] = [],
                             banners: [MarkerBanner] = []) async throws {
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

        let tempURL = temporaryURL(near: url)
        try? FileManager.default.removeItem(at: tempURL)
        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL, UTType.gif.identifier as CFString, times.count, nil)
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
            case .success(requestedTime: let requested, image: let image, actualTime: _):
                // Click rings are drawn HERE rather than by an animation tool,
                // because this path is `AVAssetImageGenerator` and that ignores
                // `AVVideoComposition.animationTool` entirely. A burn that
                // worked for mp4 and silently did nothing for GIF is the
                // failure mode worth avoiding — the caller asked for clicks and
                // would get a file without them.
                // Captions and banners draw here for the same reason the
                // rings do, and the comment above applies to them unchanged:
                // this path is `AVAssetImageGenerator`, which ignores the
                // animation tool the mp4 burn-in uses.
                let seconds = CMTimeGetSeconds(requested)
                var frame = clicks.isEmpty
                    ? image
                    : drawClicks(clicks, on: image, atOutputTime: seconds,
                                 renderSize: renderSize)
                // Text over rings, matching the mp4 layer order, so a caption
                // is never drawn underneath a ring.
                if !cues.isEmpty || !banners.isEmpty {
                    frame = TextOverlayFrame.draw(cues: cues, banners: banners, on: frame,
                                                  atOutputTime: seconds, renderSize: renderSize)
                }
                CGImageDestinationAddImage(destination, frame, frameProperties)
            case .failure(requestedTime: let time, error: let error):
                // Per-frame failures are DELIVERED, not thrown. Skipping them
                // writes a GIF that is quietly missing frames — §11 is
                // explicit that corrupt output is the worst outcome.
                try? FileManager.default.removeItem(at: tempURL)
                throw GIFError.frameGenerationFailed(
                    "frame at \(CMTimeGetSeconds(time))s: \(error.localizedDescription)")
            @unknown default:
                try? FileManager.default.removeItem(at: tempURL)
                throw GIFError.frameGenerationFailed("unknown result case")
            }
        }

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw GIFError.finalizeFailed
        }

        // Only now — with a complete, finalized GIF sitting at `tempURL` —
        // does whatever was previously at `url` get touched.
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)
    }
}
