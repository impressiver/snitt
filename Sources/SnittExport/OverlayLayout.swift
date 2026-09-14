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
