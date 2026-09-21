// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import CoreGraphics
import Foundation

/// Where captions and marker banners sit, and how big they are.
///
/// **Three renderers draw these now** — the editor's `OverlayTextView`, the
/// mp4 burn-in through `AVVideoCompositionCoreAnimationTool`, and the GIF's
/// per-frame drawing. `SubtitleCues` and `MarkerBanners` already stop them
/// disagreeing about WHEN; this stops them disagreeing about WHERE. Without
/// it, the preview and the exported file are two implementations of one design
/// and drift the moment either is touched — which is the defect this project
/// keeps finding, and the reason the click ring's geometry lives in one place
/// too.
///
/// Everything is a fraction of the PICTURE, never a fixed point size. The same
/// recording is previewed in a 600pt window and exported at 4K, and a constant
/// would make those two look like different designs.
public enum OverlayLayout {

    // MARK: - Captions

    /// 3.4% of the picture's height. Large enough to read on a phone-sized
    /// playback of a shared clip, small enough not to dominate a demo.
    public static func captionFontSize(pictureHeight: Double) -> Double {
        max(12, pictureHeight * 0.034)
    }

    /// Inset from the sides, so a long caption wraps rather than reaching the
    /// frame edge.
    public static func captionHorizontalInset(pictureWidth: Double) -> Double {
        pictureWidth * 0.08
    }

    /// Lifted off the bottom edge: a caption flush to the frame is the first
    /// thing a video player's own controls cover.
    public static func captionBottomInset(pictureHeight: Double) -> Double {
        pictureHeight * 0.07
    }

    public static func captionLineSpacing(fontSize: Double) -> Double { fontSize * 0.15 }

    // MARK: - The caption plate

    /// The translucent slab a caption sits on, the way tvOS draws one.
    ///
    /// A shadow alone is not enough and cannot be made enough. It darkens the
    /// pixels immediately around each glyph, which works over a busy but
    /// MIDDLING background and fails over a bright one: white text with a soft
    /// dark edge on a white page is still white on white. Snitt records
    /// screens, and screens are mostly bright documents, so that is the common
    /// case rather than the awkward one.
    ///
    /// A plate fixes the contrast instead of improving it: whatever is behind,
    /// the text is on a known dark ground.
    ///
    /// **It hugs the text, it does not span the frame.** A full-width bar is
    /// what a broadcast burn-in looks like; tvOS sizes the slab to the words
    /// and centres it, which is why a short caption reads as a label rather
    /// than as a letterbox.
    public static func captionPlatePadding(fontSize: Double) -> CGSize {
        // Wider than it is tall, because the corner radius eats into the
        // horizontal ends and text that starts inside the curve looks cramped.
        CGSize(width: fontSize * 0.55, height: fontSize * 0.28)
    }

    /// Rounded enough to read as a slab rather than a box, not so round it
    /// becomes a pill: at half the line height a two-line caption's corners
    /// would meet in the middle.
    public static func captionPlateCornerRadius(fontSize: Double) -> Double {
        fontSize * 0.32
    }

    /// Dark, and translucent enough that the picture still shows through.
    ///
    /// Opaque black would read as a hole punched in the video. tvOS leaves the
    /// frame visible behind its captions, which is what keeps a burn-in
    /// feeling like part of the picture rather than pasted over it.
    public static let captionPlateOpacity = 0.62

    /// Where the plate sits inside the caption's full-width box.
    ///
    /// Follows the text's own alignment, so the two-speaker offset
    /// `captionAlignment` sets up survives: a centred caption gets a centred
    /// slab, and a ragged pair gets two slabs offset from each other rather
    /// than two identical bars.
    public static func captionPlateOrigin(alignment: NSTextAlignment,
                                          plateWidth: Double,
                                          availableWidth: Double) -> Double {
        let slack = max(0, availableWidth - plateWidth)
        switch alignment {
        case .right: return slack
        case .left, .natural: return 0
        default: return slack / 2
        }
    }

    /// How far a caption is lifted for each line ABOVE the bottom one.
    ///
    /// A fixed two-line allowance rather than "however tall the caption below
    /// happens to be". Three renderers compute this, and a height that depends
    /// on the other caption's content is a height they will eventually
    /// disagree about — while a fixed step is the same arithmetic everywhere
    /// and cannot collide, since `maximumLines` is the most either can be.
    ///
    /// The cost is a small gap when the lower caption is one line. That is
    /// worth paying: a gap reads as two speakers, and an overlap reads as a
    /// broken renderer.
    public static func captionRowHeight(fontSize: Double) -> Double {
        Double(SubtitleCues.maximumLines) * (fontSize + captionLineSpacing(fontSize: fontSize))
    }

    /// The bottom inset for a caption on `row`, counting up from zero.
    public static func captionBottomInset(pictureHeight: Double, row: Int) -> Double {
        captionBottomInset(pictureHeight: pictureHeight)
            + Double(max(0, row))
            * captionRowHeight(fontSize: captionFontSize(pictureHeight: pictureHeight))
    }

    /// How a caption's own text is aligned inside its box.
    ///
    /// Centred when it is alone, ragged when it is not: the recorded voice
    /// hugs the left and narration hugs the right, so the two lines are offset
    /// from each other the way film subtitles offset two speakers. Alignment
    /// rather than a narrower box, so a long line still gets the full width
    /// instead of being wrapped for a symmetry nobody asked for.
    public static func captionAlignment(_ placement: SubtitleCue.Placement) -> NSTextAlignment {
        switch placement {
        case .alone: return .center
        case .recorded: return .left
        case .narration: return .right
        }
    }
    public static func captionShadowBlur(fontSize: Double) -> Double { fontSize * 0.35 }

    // MARK: - Marker banner

    /// Smaller than a caption. A banner is an annotation the viewer glances
    /// at; a caption is the thing they are reading.
    public static func bannerFontSize(pictureHeight: Double) -> Double {
        max(11, pictureHeight * 0.028)
    }

    /// Distance from the top-left corner of the picture.
    public static func bannerInset(pictureHeight: Double) -> Double {
        pictureHeight * 0.04
    }

    /// How far the banner is offset while animating, for a given `slide`
    /// (0…1 from `MarkerBanners.appearance`). A fraction of the width, so the
    /// motion covers the same visual distance at any resolution.
    public static func bannerTravel(pictureWidth: Double, slide: Double) -> Double {
        pictureWidth * 0.03 * slide
    }

    public static func bannerPadding(fontSize: Double) -> Double { fontSize * 0.7 }
    public static func bannerCornerRadius(fontSize: Double) -> Double { fontSize * 0.45 }

    /// The signal-coloured rule down the leading edge — never thinner than
    /// 2px, or it disappears entirely on a downscaled export.
    public static func bannerRuleWidth(fontSize: Double) -> Double {
        max(2, fontSize * 0.16)
    }

    /// The plate's rectangle, given the measured text size.
    ///
    /// Takes the picture in TOP-LEFT coordinates and returns the same, because
    /// that is the convention `ClickMark` already documents for this project.
    /// Core Animation's layer space is bottom-left; the mp4 renderer flips
    /// there, exactly as the click ring does.
    public static func bannerPlate(in picture: CGRect, textSize: CGSize,
                                   fontSize: Double, slide: Double) -> CGRect {
        let padding = bannerPadding(fontSize: fontSize)
        let inset = bannerInset(pictureHeight: picture.height)
        let travel = bannerTravel(pictureWidth: picture.width, slide: slide)
        return CGRect(x: picture.minX + inset - travel,
                      y: picture.minY + inset,
                      width: textSize.width + padding * 2,
                      height: textSize.height + padding * 0.9)
    }
}
