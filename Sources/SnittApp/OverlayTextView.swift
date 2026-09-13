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
        SubtitleCues.cue(at: time, in: cues) != nil
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

        // Scaled to the picture, not fixed in points: the same recording
        // previewed in a small window and exported at 4K should look like the
        // same design, which a constant point size would not.
        let size = max(11, picture.height * 0.028)
        let font = NSFont.systemFont(ofSize: size, weight: .semibold)
        let text = NSAttributedString(string: banner.text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(look.opacity),
        ])

        let padding = size * 0.7
        let measured = text.size()
        let inset = picture.height * 0.04
        // Slides in from the left. `slide` is 0…1 and the distance is a
        // fraction of the picture, so the motion reads the same at any size.
        let travel = picture.width * 0.03 * look.slide
        let box = CGRect(x: picture.minX + inset - travel,
                         y: picture.minY + inset,
                         width: measured.width + padding * 2,
                         height: measured.height + padding * 0.9)

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // Brand ink, from the shared palette — the reason it is its own target.
        context.setFillColor(SnittPalette.ink1.withAlphaComponent(0.92 * look.opacity).cgColor)
        let plate = NSBezierPath(roundedRect: box, xRadius: size * 0.45, yRadius: size * 0.45)
        plate.fill()
        // A signal-coloured rule down the leading edge: enough brand to be
        // recognisable without colouring the text, which has to stay legible
        // over whatever it happens to sit on.
        context.setFillColor(SnittPalette.signal.withAlphaComponent(look.opacity).cgColor)
        context.fill(CGRect(x: box.minX, y: box.minY + size * 0.45,
                            width: max(2, size * 0.16), height: box.height - size * 0.9))
        context.restoreGState()

        text.draw(at: CGPoint(x: box.minX + padding, y: box.minY + padding * 0.45))
    }

    // MARK: - Captions, bottom centre

    private func drawCaption(in picture: CGRect) {
        guard let cue = SubtitleCues.cue(at: currentTime, in: cues) else { return }

        let size = max(12, picture.height * 0.034)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = size * 0.15

        // A shadow rather than a plate: captions sit over the middle of the
        // picture far more often than a banner does, and a filled box there
        // hides more of the recording than the text needs.
        let shadow = NSShadow()
        shadow.shadowColor = SnittPalette.ink0.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = size * 0.35
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        let text = NSAttributedString(string: cue.text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
            .shadow: shadow,
        ])

        let inset = picture.width * 0.08
        let available = CGSize(width: picture.width - inset * 2, height: picture.height)
        let measured = text.boundingRect(with: available,
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        let box = CGRect(x: picture.minX + inset,
                         // Lifted off the bottom edge: a caption flush to the
                         // frame is the first thing a video player's own
                         // controls cover.
                         y: picture.maxY - measured.height - picture.height * 0.07,
                         width: available.width,
                         height: measured.height)
        text.draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
