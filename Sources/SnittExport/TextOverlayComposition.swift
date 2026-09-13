// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AVFoundation
import AppKit
import Foundation
import QuartzCore
import SnittBrand

/// Burning captions and marker banners into the exported video (D51).
///
/// Same mechanism as `ClickOverlay.exportComposition`, and deliberately the
/// same shape: one layer per thing, revealed by a `CAAnimationGroup` beginning
/// at `AVCoreAnimationBeginTimeAtZero + its output time`. D51 established that
/// this needs no custom compositor —
/// `AVVideoCompositionCoreAnimationTool` composes text at export and works
/// with `AVAssetExportSession`.
///
/// **Burned in, not a sidecar, because that is the only form that survives the
/// paste.** D51's own reasoning: Slack and Discord render neither a `.vtt` nor
/// a soft `tx3g` track, and a GIF cannot carry either. A caption nobody sees
/// is not a caption.
///
/// Layout comes from `OverlayLayout` and timing from `SubtitleCues` /
/// `MarkerBanners`, so this file decides nothing — it is the third renderer of
/// one design, and the only thing it owns is Core Animation.
public enum TextOverlayComposition {

    /// An export-only composition carrying the overlays, or nil when there is
    /// nothing to draw.
    ///
    /// Nil rather than an empty composition, matching `ClickOverlay`: the
    /// caller falls back to the shared one, and an animation tool attached for
    /// no reason forces a re-encode of every frame.
    public static func composition(from videoComposition: AVVideoComposition,
                                   cues: [SubtitleCue],
                                   banners: [MarkerBanner]) -> AVVideoComposition? {
        guard !cues.isEmpty || !banners.isEmpty else { return nil }
        let size = videoComposition.renderSize
        guard size.width > 0, size.height > 0 else { return nil }

        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: size)
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        parent.addSublayer(videoLayer)

        let picture = CGRect(origin: .zero, size: size)
        for cue in cues { parent.addSublayer(captionLayer(for: cue, picture: picture)) }
        for banner in banners { parent.addSublayer(bannerLayer(for: banner, picture: picture)) }

        var config = AVVideoComposition.Configuration()
        config.renderSize = size
        config.frameDuration = videoComposition.frameDuration
        config.instructions = videoComposition.instructions
        config.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent)
        return AVVideoComposition(configuration: config)
    }

    // MARK: - Captions

    private static func captionLayer(for cue: SubtitleCue, picture: CGRect) -> CALayer {
        let layer = CALayer()
        // Drawn by `TextOverlayFrame`, the same code the GIF uses.
        //
        // A `CATextLayer` was tried first and rendered NOTHING through
        // `AVVideoCompositionCoreAnimationTool` — a background colour proved
        // the layer itself was compositing, so the glyphs were the part that
        // did not arrive. Carrying a pre-drawn image sidesteps that and buys
        // something better: the mp4 and the GIF cannot look different, because
        // they are the same pixels.
        if let (image, box) = TextOverlayFrame.captionImage(cue, picture: picture) {
            layer.contents = image
            // Top-left rectangle into Core Animation's bottom-left space, the
            // same flip `ClickOverlay.ringLayer` performs.
            layer.frame = CGRect(x: box.minX, y: picture.height - box.maxY,
                                 width: box.width, height: box.height)
        }
        reveal(layer, from: cue.start, to: cue.end)
        return layer
    }

    // MARK: - Marker banners

    private static func bannerLayer(for banner: MarkerBanner, picture: CGRect) -> CALayer {
        let layer = CALayer()
        var restingX = 0.0
        if let (image, box) = TextOverlayFrame.bannerImage(banner, picture: picture) {
            layer.contents = image
            layer.frame = CGRect(x: box.minX, y: picture.height - box.maxY,
                                 width: box.width, height: box.height)
            restingX = box.minX
        }
        slideIn(layer, banner: banner, picture: picture, restingX: restingX)
        return layer
    }

    // MARK: - Animation

    /// Shows a layer between two output times and hides it either side.
    ///
    /// `isRemovedOnCompletion = false` with `fillMode = .backwards` is the same
    /// arrangement `ClickOverlay` uses, and for the same reason: the layer must
    /// be invisible before its moment and must not linger after it.
    private static func reveal(_ layer: CALayer, from start: Double, to end: Double) {
        layer.opacity = 0
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        // A short cross-fade at each edge rather than a hard cut. A caption
        // that pops reads as a rendering glitch at 60fps.
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.08, 0.92, 1]
        fade.beginTime = AVCoreAnimationBeginTimeAtZero + start
        fade.duration = max(0.05, end - start)
        fade.isRemovedOnCompletion = false
        fade.fillMode = .backwards
        layer.add(fade, forKey: "caption")
    }

    private static func slideIn(_ layer: CALayer, banner: MarkerBanner,
                                picture: CGRect, restingX: Double) {
        layer.opacity = 0

        // Sampled from `MarkerBanners.appearance` rather than re-derived, so
        // the burned-in curve IS the previewed curve. Keyframes because the
        // easing differs between entry and exit — one `CABasicAnimation` with
        // a timing function could not express both.
        let steps = 24
        var opacities: [Double] = []
        var positions: [Double] = []
        var times: [Double] = []
        for step in 0...steps {
            let fraction = Double(step) / Double(steps)
            let at = banner.appearsAt + fraction * banner.totalSeconds
            let look = MarkerBanners.appearance(of: banner, at: at) ?? (opacity: 0, slide: 1)
            opacities.append(look.opacity)
            positions.append(restingX
                - OverlayLayout.bannerTravel(pictureWidth: picture.width, slide: look.slide)
                + layer.bounds.width / 2)
            times.append(fraction)
        }

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = opacities
        fade.keyTimes = times.map(NSNumber.init)

        let slide = CAKeyframeAnimation(keyPath: "position.x")
        slide.values = positions
        slide.keyTimes = times.map(NSNumber.init)

        let group = CAAnimationGroup()
        group.animations = [fade, slide]
        group.beginTime = AVCoreAnimationBeginTimeAtZero + banner.appearsAt
        group.duration = max(0.05, banner.totalSeconds)
        group.isRemovedOnCompletion = false
        group.fillMode = .backwards
        layer.add(group, forKey: "banner")
    }
}
