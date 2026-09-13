// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittDocument

/// A marker, shown as a banner at the top-left of the frame.
public struct MarkerBanner: Equatable, Sendable {
    /// OUTPUT time at which the banner begins animating in.
    public let appearsAt: Double
    public let text: String
    /// How long it sits fully visible, before animating out.
    public let holdSeconds: Double

    public init(appearsAt: Double, text: String, holdSeconds: Double) {
        self.appearsAt = appearsAt
        self.text = text
        self.holdSeconds = holdSeconds
    }

    public var totalSeconds: Double {
        MarkerBanners.animateInSeconds + holdSeconds + MarkerBanners.animateOutSeconds
    }

    public var endsAt: Double { appearsAt + totalSeconds }
}

/// How a marker banner enters, waits and leaves.
///
/// **Top-left, and a different shape from a subtitle, because it is a
/// different statement.** A caption is what someone said; a banner is what
/// they noted — "the bug reproduces here". Drawing both as captions would
/// stack two kinds of text in one place and make the recording's own
/// annotations look like speech.
///
/// The curve lives here, as data, for the same reason `ClickOverlay.ring`
/// does: the export burns frames through `AVVideoCompositionCoreAnimationTool`
/// while the editor draws into a layer, and two implementations of one easing
/// curve drift the moment either is touched. Both ask this.
public enum MarkerBanners {

    /// Slightly slower in than out. Entry is information arriving and wants to
    /// be noticed; exit is it leaving and should not compete with the frame.
    public static let animateInSeconds = 0.28
    public static let animateOutSeconds = 0.22

    /// Read time uses the SAME constants as the captions
    /// (`WebVTTSubtitles.wordsPerSecond` and its bounds). A banner and a
    /// caption are both text somebody has to read; two different reading
    /// speeds in one frame would be indefensible.
    public static var wordsPerSecond: Double { WebVTTSubtitles.wordsPerSecond }
    public static var minimumHoldSeconds: Double { WebVTTSubtitles.minimumCueSeconds }
    public static var maximumHoldSeconds: Double { WebVTTSubtitles.maximumCueSeconds }

    /// Banners in OUTPUT time, from a recording's marker events.
    ///
    /// Uses a marker's `label` — the thing a person typed to mark the moment.
    /// A marker's `transcript` field belongs to the captions, and D50's
    /// distinction holds: a label is a note, a transcript is speech.
    public static func banners(events: [LoggedEvent],
                               keptRanges: [TimeRange]) -> [MarkerBanner] {
        guard !keptRanges.isEmpty else { return [] }
        let placed = events.compactMap { event -> MarkerBanner? in
            guard event.kind == .marker else { return nil }
            let label = (event.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // An unlabelled marker is a navigation point, not an annotation.
            // Drawing an empty banner for it would put a branded rectangle on
            // the frame saying nothing.
            guard !label.isEmpty else { return nil }
            guard let start = TimeRangeMapping.trimmedTime(of: event.timeSeconds,
                                                           keptRanges: keptRanges)
            else { return nil }
            return MarkerBanner(appearsAt: start, text: label,
                                holdSeconds: hold(for: label))
        }
        return resolveOverlaps(placed.sorted { $0.appearsAt < $1.appearsAt })
    }

    static func hold(for text: String) -> Double {
        let words = text.split(whereSeparator: \.isWhitespace).count
        let readable = Double(max(1, words)) / wordsPerSecond
        return min(maximumHoldSeconds, max(minimumHoldSeconds, readable))
    }

    /// Two banners must never be on screen together.
    ///
    /// They occupy the same corner, so an overlap is not a subtle layout
    /// problem — the second draws on top of the first and both become
    /// unreadable. The earlier one is cut short rather than the later one
    /// delayed: a banner that appears after the moment it marks is pointing at
    /// the wrong frame, which is worse than one that leaves early.
    private static func resolveOverlaps(_ banners: [MarkerBanner]) -> [MarkerBanner] {
        guard banners.count > 1 else { return banners }
        var out: [MarkerBanner] = []
        for (index, banner) in banners.enumerated() {
            guard index + 1 < banners.count else { out.append(banner); break }
            let next = banners[index + 1].appearsAt
            let available = next - banner.appearsAt - animateInSeconds - animateOutSeconds
            if available < banner.holdSeconds {
                // Never negative: two markers a tenth of a second apart give
                // the first no hold at all, which reads as a flash rather than
                // as a banner drawn underneath the next one.
                out.append(MarkerBanner(appearsAt: banner.appearsAt, text: banner.text,
                                        holdSeconds: max(0, available)))
            } else {
                out.append(banner)
            }
        }
        return out
    }

    /// How a banner looks at `outputTime`, or nil when it is not on screen.
    ///
    /// - Returns: `opacity` 0…1, and `slide` 0…1 where 1 is fully offset to
    ///   the left of its resting place. The renderer multiplies `slide` by
    ///   whatever offset suits the frame size, so this stays resolution-free —
    ///   the same reason click positions are fractions.
    public static func appearance(of banner: MarkerBanner,
                                  at outputTime: Double) -> (opacity: Double, slide: Double)? {
        let elapsed = outputTime - banner.appearsAt
        guard elapsed >= 0, elapsed < banner.totalSeconds else { return nil }

        if elapsed < animateInSeconds {
            let t = elapsed / animateInSeconds
            // Ease-out: fast at first, settling. Motion that decelerates reads
            // as something arriving and stopping; linear reads as a slide.
            let eased = 1 - pow(1 - t, 3)
            return (opacity: eased, slide: 1 - eased)
        }

        let afterHold = elapsed - animateInSeconds - banner.holdSeconds
        if afterHold <= 0 { return (opacity: 1, slide: 0) }

        let t = min(1, afterHold / animateOutSeconds)
        // Ease-in on the way out — accelerating away draws less attention than
        // the symmetric curve would.
        let eased = t * t
        let opacity = 1 - eased
        // Below visibility IS gone, and saying so matters beyond the pixels:
        // callers use a non-nil answer to decide whether to keep redrawing.
        // At exactly `endsAt` the guard above passes by about 4e-16 — the sum
        // in `totalSeconds` and the subtraction here do not round identically
        // — and returned an opacity of 2e-15, which draws nothing and keeps a
        // redraw loop alive for ever.
        guard opacity > 0.001 else { return nil }
        return (opacity: opacity, slide: eased)
    }

    /// The banner that should be drawn at `outputTime`, if any.
    public static func banner(at outputTime: Double,
                              in banners: [MarkerBanner]) -> MarkerBanner? {
        banners.last { $0.appearsAt <= outputTime && outputTime < $0.endsAt }
    }
}
