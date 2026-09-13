// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import CoreGraphics
import Foundation
import SnittBrand

/// Captions and marker banners drawn into a single frame.
///
/// The GIF path, and the third renderer of one design. It exists because
/// `AVAssetImageGenerator` ignores `AVVideoComposition.animationTool`
/// entirely — `GIFExporter` already records that for click rings, and the
/// failure it names applies here exactly: a burn that worked for mp4 and
/// silently did nothing for GIF gives the caller a file without the captions
/// they asked for.
///
/// Timing comes from `SubtitleCues` / `MarkerBanners`, layout from
/// `OverlayLayout`. This file owns only Core Graphics.
enum TextOverlayFrame {

    /// The caption as an image, and where it belongs in TOP-LEFT coordinates.
    ///
    /// Exists so the mp4 burn-in can use the SAME pixels: a `CATextLayer` with
    /// an `NSAttributedString` rendered nothing at all through
    /// `AVVideoCompositionCoreAnimationTool` — the layer drew (a background
    /// colour proved it) and the glyphs did not. Rather than find the
    /// incantation that makes CATextLayer cooperate, both paths now draw with
    /// Core Graphics and the mp4 layer carries the result as `contents`. Two
    /// renderers became one, and the export cannot look different from the GIF
    /// because it is the same drawing.
    static func captionImage(_ cue: SubtitleCue, picture: CGRect) -> (CGImage, CGRect)? {
        let size = OverlayLayout.captionFontSize(pictureHeight: picture.height)
        let inset = OverlayLayout.captionHorizontalInset(pictureWidth: picture.width)
        let text = captionText(cue, fontSize: size)
        let available = CGSize(width: picture.width - inset * 2, height: picture.height)
        let measured = text.boundingRect(
            with: available, options: [.usesLineFragmentOrigin, .usesFontLeading])
        // Padded, so the shadow is not clipped at the edges of the bitmap.
        let pad = OverlayLayout.captionShadowBlur(fontSize: size) * 2
        let box = CGRect(x: picture.minX + inset,
                         y: picture.maxY - ceil(measured.height) - pad * 2
                            - OverlayLayout.captionBottomInset(pictureHeight: picture.height),
                         width: available.width,
                         height: ceil(measured.height) + pad * 2)
        guard let image = render(size: box.size, { _ in
            text.draw(with: CGRect(x: 0, y: pad, width: available.width,
                                   height: ceil(measured.height)),
                      options: [.usesLineFragmentOrigin, .usesFontLeading])
        }) else { return nil }
        return (image, box)
    }

    /// The banner at rest, as an image, in TOP-LEFT coordinates.
    static func bannerImage(_ banner: MarkerBanner, picture: CGRect) -> (CGImage, CGRect)? {
        let size = OverlayLayout.bannerFontSize(pictureHeight: picture.height)
        let padding = OverlayLayout.bannerPadding(fontSize: size)
        let text = bannerText(banner, fontSize: size, opacity: 1)
        let box = OverlayLayout.bannerPlate(in: picture, textSize: text.size(),
                                            fontSize: size, slide: 0)
        let radius = OverlayLayout.bannerCornerRadius(fontSize: size)
        guard let image = render(size: box.size, { context in
            let local = CGRect(origin: .zero, size: box.size)
            context.setFillColor(SnittPalette.ink1.withAlphaComponent(0.92).cgColor)
            NSBezierPath(roundedRect: local, xRadius: radius, yRadius: radius).fill()
            context.setFillColor(SnittPalette.signal.cgColor)
            context.fill(CGRect(x: 0, y: radius,
                                width: OverlayLayout.bannerRuleWidth(fontSize: size),
                                height: local.height - radius * 2))
            text.draw(at: CGPoint(x: padding, y: padding * 0.45))
        }) else { return nil }
        return (image, box)
    }

    private static func captionText(_ cue: SubtitleCue, fontSize: Double) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = OverlayLayout.captionLineSpacing(fontSize: fontSize)
        let shadow = NSShadow()
        shadow.shadowColor = SnittPalette.ink0.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = OverlayLayout.captionShadowBlur(fontSize: fontSize)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return NSAttributedString(string: cue.text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
            .shadow: shadow,
        ])
    }

    private static func bannerText(_ banner: MarkerBanner, fontSize: Double,
                                   opacity: Double) -> NSAttributedString {
        NSAttributedString(string: banner.text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(opacity),
        ])
    }

    /// A transparent bitmap with `body` drawn into it, bottom-left origin.
    private static func render(size: CGSize, _ body: (CGContext) -> Void) -> CGImage? {
        let width = Int(ceil(size.width)), height = Int(ceil(size.height))
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        body(context)
        NSGraphicsContext.current = previous
        return context.makeImage()
    }


    /// `image` with the overlays for `outputTime` drawn on, or the original
    /// when there is nothing at that moment.
    ///
    /// Returns the input unchanged on any drawing failure, matching
    /// `GIFExporter.drawClicks`: losing an overlay costs an annotation, while
    /// throwing would lose the whole export.
    static func draw(cues: [SubtitleCue], banners: [MarkerBanner],
                     on image: CGImage, atOutputTime outputTime: Double,
                     renderSize: CGSize) -> CGImage {
        let cue = SubtitleCues.cue(at: outputTime, in: cues)
        let banner = MarkerBanners.banner(at: outputTime, in: banners)
        guard cue != nil || banner != nil else { return image }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }

        let picture = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        context.draw(image, in: picture)

        // AppKit draws through the current context, and its coordinate space
        // is bottom-left here — the flip is applied per element below rather
        // than globally, so `OverlayLayout`'s top-left rectangles stay the
        // same numbers the preview uses.
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }

        if let banner, let look = MarkerBanners.appearance(of: banner, at: outputTime) {
            drawBanner(banner, look: look, picture: picture, context: context)
        }
        if let cue {
            drawCaption(cue, picture: picture, context: context)
        }

        return context.makeImage() ?? image
    }

    private static func drawBanner(_ banner: MarkerBanner,
                                   look: (opacity: Double, slide: Double),
                                   picture: CGRect, context: CGContext) {
        guard let (image, box) = bannerImage(banner, picture: picture) else { return }
        let travel = OverlayLayout.bannerTravel(pictureWidth: picture.width, slide: look.slide)
        // Top-left rectangle into a bottom-left context.
        let target = CGRect(x: box.minX - travel, y: picture.height - box.maxY,
                            width: box.width, height: box.height)
        context.saveGState()
        context.setAlpha(look.opacity)
        context.draw(image, in: target)
        context.restoreGState()
    }

    private static func drawCaption(_ cue: SubtitleCue, picture: CGRect,
                                    context: CGContext) {
        guard let (image, box) = captionImage(cue, picture: picture) else { return }
        let target = CGRect(x: box.minX, y: picture.height - box.maxY,
                            width: box.width, height: box.height)
        context.draw(image, in: target)
    }
}
