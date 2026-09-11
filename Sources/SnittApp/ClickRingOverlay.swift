// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AVFoundation
import AppKit
import SnittExport

/// Click rings drawn over the editor's video, in playback.
///
/// **Not the export's mechanism, and it cannot be.** The export burns rings in
/// with `AVVideoCompositionCoreAnimationTool`, which `MovieExporter` already
/// records as unusable here: an `animationTool` set on a composition that an
/// `AVPlayerItem` also holds breaks playback (V5). So playback draws its own,
/// and the two paths share the thing that must not diverge — `ClickOverlay.ring`,
/// which owns the geometry both of them ask for.
///
/// The rectangle to draw into is `AVPlayerLayer.videoRect`, never the view's
/// bounds. `videoGravity = .resizeAspect` letterboxes the picture inside
/// whatever the window gives it, so a ring placed against `bounds` drifts off
/// the recording by exactly the size of the bars — correct only when the
/// window's aspect happens to match the video's, which is the one case someone
/// resizing to test would land on by accident.
final class ClickRingOverlayView: NSView {

    /// Marks whose positions are FRACTIONS of the picture (`unitMarks`), so
    /// this view can multiply by `videoRect` at draw time and stay correct
    /// through every resize.
    var marks: [ClickMark] = [] {
        didSet { needsDisplay = true }
    }

    /// Where playback is, in OUTPUT time — the same clock `ClickMark.outputTime`
    /// uses, because the player is playing the trimmed composition.
    var currentTime: Double = 0 {
        didSet {
            // Redrawn only when a ring is actually on screen or has just left.
            // A recording with no clicks near the playhead should cost nothing
            // per frame, and this view sits over a video that is already
            // decoding.
            if hasVisibleRing(at: currentTime) || hasVisibleRing(at: oldValue) {
                needsDisplay = true
            }
        }
    }

    /// The picture's rectangle inside this view, supplied by the layer that
    /// knows it. A closure rather than a stored rect so it cannot go stale
    /// between a resize and the next draw.
    var videoRect: () -> CGRect = { .zero }

    override var isFlipped: Bool {
        // Top-left origin, matching `ClickMark`'s documented convention, so the
        // fraction needs no flip here. The one place a flip would be invisible
        // is exactly this one: every ring would still land on the picture.
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Never takes a click. This view sits over the player during ordinary
        // playback — unlike `CropDragOverlay`, which is only present while
        // cropping — so swallowing events would break scrubbing and every
        // gesture the player surface answers.
        nil
    }

    private func hasVisibleRing(at time: Double) -> Bool {
        marks.contains { $0.outputTime <= time && time - $0.outputTime < ClickOverlay.ringDuration }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let picture = videoRect()
        guard picture.width > 0, picture.height > 0 else { return }

        for mark in marks {
            let elapsed = currentTime - mark.outputTime
            // Asking `ClickOverlay` rather than re-deriving: the export's rings
            // and these must expand and fade identically, and two copies of an
            // easing curve drift the moment either is touched.
            guard let ring = ClickOverlay.ring(elapsed: elapsed, renderSize: picture.size)
            else { continue }

            let centre = CGPoint(x: picture.minX + mark.position.x * picture.width,
                                 y: picture.minY + mark.position.y * picture.height)
            context.saveGState()
            context.setStrokeColor(NSColor.white.withAlphaComponent(ring.opacity).cgColor)
            context.setLineWidth(max(1.5, picture.width * 0.0025))
            context.strokeEllipse(in: CGRect(x: centre.x - ring.radius,
                                             y: centre.y - ring.radius,
                                             width: ring.radius * 2,
                                             height: ring.radius * 2))
            context.restoreGState()
        }
    }
}
