// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore
import SnittDocument

/// One click, placed where it belongs in the exported frame.
public struct ClickMark: Equatable, Sendable {
    /// When it appears, on the EDIT's clock. A click inside a cut has no output
    /// time and never becomes a mark.
    public let outputTime: Double
    /// Where it appears, in render pixels with a TOP-LEFT origin — the same
    /// way the frame is described everywhere else in this project. Each drawing
    /// site flips for its own coordinate space; doing it here would mean two
    /// conventions in one type.
    public let position: CGPoint

    public init(outputTime: Double, position: CGPoint) {
        self.outputTime = outputTime
        self.position = position
    }
}

/// Drawing clicks onto the exported video (D64).
///
/// **Only reported clicks can be drawn, and that is not a limitation of this
/// code.** `InputEventMonitor` records observed clicks with no coordinates at
/// all — a `CGEventTap` sees screen positions, and turning one into a position
/// within the recorded window needs that window's frame at that instant, which
/// nothing records (D64 names the window-frame track as the prerequisite).
/// Reported input (D72) carries a fraction of the window instead, which is
/// exact forever and survives the window being moved afterwards. So this works
/// today for the recordings that most need it — an agent's, where every click
/// is reported precisely because it never reached the screen.
public enum ClickOverlay {

    /// How long a ring stays on screen.
    ///
    /// Long enough to notice at ordinary playback and short enough not to sit
    /// over the thing it is pointing at. A viewer scrubbing will miss some of
    /// them regardless; the ring exists so a click has a visible cause, not so
    /// it can be paused on.
    public static let ringDuration = 0.6

    /// The ring at `elapsed` seconds after its click, or nil when it is over.
    ///
    /// Expands and fades: a fixed dot reads as a UI element belonging to the
    /// recorded app, while something that grows and vanishes reads as an event.
    /// Returned rather than drawn so the mp4 burn and the GIF frames get
    /// identical geometry from one place.
    public static func ring(elapsed: Double, renderSize: CGSize)
        -> (radius: Double, opacity: Double)? {
        guard elapsed >= 0, elapsed < ringDuration else { return nil }
        let progress = elapsed / ringDuration
        // Proportional to the shorter side so a ring is the same visual size at
        // any export scale, with a floor so it does not vanish on a small one.
        let maxRadius = max(8, min(renderSize.width, renderSize.height) * 0.035)
        return (radius: maxRadius * (0.45 + 0.55 * progress),
                opacity: 0.85 * (1 - progress * progress))
    }

    /// Where and when each reported click lands in the edit.
    ///
    /// - Parameter keptRanges: the composition's own kept ranges, so a click
    ///   inside a cut is dropped rather than drawn at a moment it did not
    ///   happen — the same rule `MarkerJumpPoints` applies to markers.
    /// Marks whose `position` is a FRACTION of the picture, not render pixels.
    ///
    /// Playback needs this instead of `marks(…)`. The export knows exactly how
    /// big its frame is and bakes positions into it; the editor's player does
    /// not — `AVPlayerLayer` letterboxes the video inside whatever the window
    /// gives it, and that rectangle changes as the user resizes. Handing the
    /// overlay a fraction lets it multiply by `videoRect` at draw time, which
    /// is the only rectangle that is actually correct.
    ///
    /// The unit size is what makes this work: `marks(…)` multiplies the stored
    /// fraction by `naturalSize` and applies `renderTransform`, so a 1×1 size
    /// and the identity transform give the fraction back unchanged — while
    /// still doing the part that matters here, mapping each click's source time
    /// through the cuts to an output time. One implementation, two framings.
    public static func unitMarks(events: [LoggedEvent],
                                 keptRanges: [TimeRange]) -> [ClickMark] {
        marks(events: events, keptRanges: keptRanges,
              naturalSize: CGSize(width: 1, height: 1),
              renderTransform: .identity)
    }

    public static func marks(events: [LoggedEvent],
                             keptRanges: [TimeRange],
                             naturalSize: CGSize,
                             renderTransform: CGAffineTransform) -> [ClickMark] {
        guard !keptRanges.isEmpty else { return [] }
        return events.compactMap { event -> ClickMark? in
            guard event.kind == .click, let x = event.x, let y = event.y else { return nil }
            guard let outputTime = TimeRangeMapping.trimmedTime(of: event.timeSeconds,
                                                                keptRanges: keptRanges)
            else { return nil }
            // Fraction of the window becomes source pixels, then goes through
            // the very transform the picture went through.
            let source = CGPoint(x: x * naturalSize.width, y: y * naturalSize.height)
            return ClickMark(outputTime: outputTime,
                             position: source.applying(renderTransform))
        }.sorted { $0.outputTime < $1.outputTime }
    }

    /// Draw every ring visible at `outputTime` into a context whose coordinate
    /// space has a TOP-LEFT origin.
    ///
    /// White with a dark rim on purpose: a demo is recorded over whatever the
    /// app happens to look like, and a single-colour ring disappears against
    /// half of them.
    public static func draw(marks: [ClickMark], atOutputTime outputTime: Double,
                            renderSize: CGSize, into context: CGContext) {
        for mark in marks {
            guard let ring = ring(elapsed: outputTime - mark.outputTime,
                                  renderSize: renderSize) else { continue }
            let rect = CGRect(x: mark.position.x - ring.radius,
                              y: mark.position.y - ring.radius,
                              width: ring.radius * 2, height: ring.radius * 2)
            context.setLineWidth(max(2, ring.radius * 0.18))
            context.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0,
                                           alpha: ring.opacity * 0.55))
            context.strokeEllipse(in: rect.insetBy(dx: -1, dy: -1))
            context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1,
                                           alpha: ring.opacity))
            context.strokeEllipse(in: rect)
        }
    }
}


extension ClickOverlay {

    /// An export-only copy of `videoComposition` with the click rings burned in.
    ///
    /// A COPY, deliberately. §9 makes preview and export share one composition,
    /// and V5 is that `animationTool` cannot be used with `AVPlayerItem` — so
    /// setting it on the shared object would break playback to decorate the
    /// export. This is D51's ruling applied again: the editor is a
    /// representation, the export is its realization.
    ///
    /// Returns nil when there is nothing to draw, so the caller keeps using the
    /// shared composition and no copy exists at all.
    public static func exportComposition(from videoComposition: AVVideoComposition,
                                         marks: [ClickMark]) -> AVVideoComposition? {
        guard !marks.isEmpty else { return nil }
        let size = videoComposition.renderSize
        guard size.width > 0, size.height > 0 else { return nil }

        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: size)
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        parent.addSublayer(videoLayer)

        for mark in marks {
            parent.addSublayer(ringLayer(for: mark, renderSize: size))
        }

        var config = AVVideoComposition.Configuration()
        config.renderSize = size
        config.frameDuration = videoComposition.frameDuration
        config.instructions = videoComposition.instructions
        config.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent)
        return AVVideoComposition(configuration: config)
    }

    /// One ring, animated over its own lifetime.
    ///
    /// The animation reproduces `ring(elapsed:renderSize:)` rather than
    /// inventing a second curve, so the mp4 burn and the GIF frames agree about
    /// what a click looks like. Core Animation interpolates between the same
    /// endpoints that function returns at 0 and at `ringDuration`.
    private static func ringLayer(for mark: ClickMark, renderSize: CGSize) -> CALayer {
        let start = ring(elapsed: 0, renderSize: renderSize)
            ?? (radius: 8.0, opacity: 0.85)
        let end = ring(elapsed: ringDuration * 0.999, renderSize: renderSize)
            ?? (radius: 8.0, opacity: 0.0)

        let layer = CAShapeLayer()
        let box = CGRect(x: -end.radius, y: -end.radius,
                         width: end.radius * 2, height: end.radius * 2)
        layer.path = CGPath(ellipseIn: box, transform: nil)
        layer.fillColor = nil
        layer.strokeColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        layer.lineWidth = max(2, end.radius * 0.18)
        layer.shadowColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        layer.shadowOpacity = 0.55
        layer.shadowRadius = 1
        layer.shadowOffset = .zero
        // Core Animation's layer space has a BOTTOM-LEFT origin; ClickMark uses
        // top-left, the same flip the GIF path performs.
        layer.position = CGPoint(x: mark.position.x, y: renderSize.height - mark.position.y)
        layer.bounds = box
        layer.opacity = 0
        layer.isHidden = true

        let begin = AVCoreAnimationBeginTimeAtZero + mark.outputTime
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = start.radius / end.radius
        grow.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = start.opacity
        fade.toValue = 0.0
        let reveal = CABasicAnimation(keyPath: "hidden")
        reveal.fromValue = false
        reveal.toValue = false

        let group = CAAnimationGroup()
        group.animations = [grow, fade, reveal]
        group.beginTime = begin
        group.duration = ringDuration
        // Removed on completion would restore opacity 0 and hidden — which is
        // what is wanted, since the ring must not linger for the rest of the
        // video.
        group.isRemovedOnCompletion = false
        group.fillMode = .backwards
        layer.add(group, forKey: "click")
        return layer
    }
}
