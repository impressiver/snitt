// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import SnittBrand
import SnittExport

/// Captions and marker banners, drawn over the editor's video.
///
/// The sibling of `ClickRingOverlayView`, and separate from it for the same
/// reason the click overlay is separate from the export's animation tool: this
/// is the PREVIEW. The export burns the same geometry into frames, and both
/// ask `SubtitleCues` and `MarkerBanners` rather than deciding anything here.
/// What lives in this file is drawing — fonts, insets, corner radii — and
/// nothing about when.
///
/// Everything is sized from `videoRect`, never from the view's bounds.
/// `videoGravity = .resizeAspect` letterboxes the picture, so text placed
/// against the bounds sits on the black bars at some window sizes and on the
/// recording at others.
final class OverlayTextView: NSView {

    var cues: [SubtitleCue] = [] { didSet { needsDisplay = true } }
    var banners: [MarkerBanner] = [] { didSet { needsDisplay = true } }

    var currentTime: Double = 0 {
        didSet {
            // Only redraw when something is or was on screen. This view sits
            // over a decoding video and is asked ~30 times a second.
            if isShowingAnything(at: currentTime) || isShowingAnything(at: oldValue) {
                needsDisplay = true
            }
        }
    }

    /// The picture's rectangle inside this view, from the layer that knows it.
    var videoRect: () -> CGRect = { .zero }

    override var isFlipped: Bool { true }

    /// Never takes a click — it covers the player during ordinary playback.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func isShowingAnything(at time: Double) -> Bool {
        !SubtitleCues.visible(at: time, in: cues).isEmpty
            || MarkerBanners.banner(at: time, in: banners) != nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let picture = videoRect()
        guard picture.width > 0, picture.height > 0 else { return }
        drawBanner(in: picture)
        drawCaption(in: picture)
    }

    // MARK: - Marker banner, top-left

    private func drawBanner(in picture: CGRect) {
        guard let banner = MarkerBanners.banner(at: currentTime, in: banners),
              let look = MarkerBanners.appearance(of: banner, at: currentTime)
        else { return }

        // Every number here comes from `OverlayLayout`, which the mp4 and GIF
        // renderers also ask. Three copies of one design is how the preview
        // and the exported file stop matching.
        let size = OverlayLayout.bannerFontSize(pictureHeight: picture.height)
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let text = NSAttributedString(string: banner.text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(look.opacity),
        ])

        let padding = OverlayLayout.bannerPadding(fontSize: size)
        let box = OverlayLayout.bannerPlate(in: picture, textSize: text.size(),
                                            fontSize: size, slide: look.slide)

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // Brand ink, from the shared palette — the reason it is its own target.
        context.setFillColor(SnittPalette.ink1.withAlphaComponent(0.92 * look.opacity).cgColor)
        let radius = OverlayLayout.bannerCornerRadius(fontSize: size)
        let plate = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
        plate.fill()
        // A signal-coloured rule down the leading edge: enough brand to be
        // recognisable without colouring the text, which has to stay legible
        // over whatever it happens to sit on.
        context.setFillColor(SnittPalette.signal.withAlphaComponent(look.opacity).cgColor)
        context.fill(CGRect(x: box.minX, y: box.minY + radius,
                            width: OverlayLayout.bannerRuleWidth(fontSize: size),
                            height: box.height - radius * 2))
        context.restoreGState()

        text.draw(at: CGPoint(x: box.minX + padding, y: box.minY + padding * 0.45))
    }

    // MARK: - Captions, bottom centre — or two lines when two voices overlap

    private func drawCaption(in picture: CGRect) {
        // All of them, not the last one. Narration is spoken OVER footage that
        // already has speech in it, so two simultaneous captions is the normal
        // case here rather than an edge one.
        for cue in SubtitleCues.visible(at: currentTime, in: cues) {
            drawCaption(cue, in: picture)
        }
    }

    private func drawCaption(_ cue: SubtitleCue, in picture: CGRect) {
        let size = OverlayLayout.captionFontSize(pictureHeight: picture.height)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = OverlayLayout.captionAlignment(cue.placement)
        paragraph.lineSpacing = OverlayLayout.captionLineSpacing(fontSize: size)

        // A shadow rather than a plate: captions sit over the middle of the
        // picture far more often than a banner does, and a filled box there
        // hides more of the recording than the text needs.
        let shadow = NSShadow()
        shadow.shadowColor = SnittPalette.ink0.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = OverlayLayout.captionShadowBlur(fontSize: size)
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        let text = NSAttributedString(string: cue.text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: SnittPalette.caption(for: cue.track),
            .paragraphStyle: paragraph,
            .shadow: shadow,
        ])

        let inset = OverlayLayout.captionHorizontalInset(pictureWidth: picture.width)
        let available = CGSize(width: picture.width - inset * 2, height: picture.height)
        let measured = text.boundingRect(with: available,
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        let box = CGRect(x: picture.minX + inset,
                         // Lifted off the bottom edge: a caption flush to the
                         // frame is the first thing a video player's own
                         // controls cover.
                         y: picture.maxY - measured.height
                            - OverlayLayout.captionBottomInset(pictureHeight: picture.height,
                                                               row: cue.row),
                         width: available.width,
                         height: measured.height)
        text.draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
