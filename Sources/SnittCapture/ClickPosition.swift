// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import CoreGraphics
import Foundation

/// Where a click landed inside the recorded picture (D64).
///
/// A click arrives from `CGEventTap` as a point on the *desktop*. What the
/// event log stores is a fraction of the captured content — 0…1 on each axis —
/// because that is the only form that survives everything that happens
/// afterwards: the window being moved or resized after the recording, the
/// export being scaled down a size ladder, the display being disconnected.
/// `ClickOverlay` multiplies the fraction back out by the render size at draw
/// time, so one recording exports correctly at every resolution.
///
/// **Why this is a type and not two lines at the call site.** Both inputs are
/// `CGRect`/`CGPoint` in *some* coordinate space, and the spaces differ by a
/// vertical flip depending on which framework produced them. A flip here is
/// invisible: every click still lands inside the frame, still draws a ring,
/// and the ring is simply in the wrong place — the "correct model, no pixels"
/// defect this project keeps finding. Isolating the conversion gives that
/// decision one name, one place, and its own tests.
public enum ClickPosition {

    /// Both inputs are CoreGraphics global display coordinates, TOP-LEFT
    /// origin, in points.
    ///
    /// This is an assertion about two frameworks and it is the load-bearing
    /// assumption of the whole feature, so it is written down rather than
    /// implied:
    ///
    /// - `CGEvent.location` is documented in global display coordinates, which
    ///   CoreGraphics measures from the top-left of the main display. It is
    ///   *not* AppKit's `NSEvent.mouseLocation`, which is bottom-left.
    /// - `SCStreamFrameInfoScreenRect` is "the onscreen location of the
    ///   captured content", and ScreenCaptureKit reports window geometry the
    ///   way `kCGWindowBounds` does — top-left.
    ///
    /// Agreeing means no flip. If that is ever wrong the symptom is specific
    /// and worth recognising: rings appear mirrored about the horizontal
    /// midline, exactly right for a click at the vertical centre and
    /// increasingly wrong towards the edges.
    ///
    /// - Parameters:
    ///   - point: where the click happened, on the desktop.
    ///   - content: the captured content's rectangle on the desktop, for the
    ///     frame current at that moment. For a display capture this is fixed
    ///     for the whole recording; for a window capture it moves whenever the
    ///     window does, which is why it is a parameter rather than a constant.
    /// - Returns: the fraction of the content, or `nil` when the click was
    ///   outside it. Outside is the common case, not an error — a click on
    ///   another window, another display, or the menu bar is a real click that
    ///   simply has no place in this picture.
    public static func fraction(ofScreenPoint point: CGPoint,
                                inContent content: CGRect) -> CGPoint? {
        // No separate guard for a degenerate rect, deliberately. A zero width
        // divides to NaN (when the click is exactly on the edge) or ±infinity
        // (otherwise), and the half-open range check below rejects all three —
        // a `contains` against NaN is false, not a trap. An explicit guard here
        // survived its own mutant because it could not change any answer;
        // `degenerateRectIsNil` still pins the behaviour, now against the check
        // that actually produces it.
        let x = (point.x - content.minX) / content.width
        let y = (point.y - content.minY) / content.height

        // Half-open on the far edge deliberately: a click at exactly
        // `content.maxX` belongs to whatever is beyond the content, and a
        // fraction of exactly 1.0 would index one pixel past the frame.
        guard (0..<1).contains(x), (0..<1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }
}

/// The captured content's position on the desktop, as of the most recent frame.
///
/// A window capture's geometry is not a constant — the user can drag the
/// recorded window mid-recording, and every click after that maps against a
/// rectangle that has moved. ScreenCaptureKit already answers this per frame
/// via `SCStreamFrameInfoScreenRect`, so this is a place to *keep* that answer
/// rather than a thing that computes it.
///
/// **Read from the event tap's callback, written from the capture queue**, so
/// it is lock-protected rather than actor-isolated: the tap callback is
/// `nonisolated` and cannot await, and macOS disables a tap whose callback runs
/// long. `Recorder` already establishes this pattern for the recording clock —
/// values the callback needs are captured or read without hopping.
public final class CapturedContentGeometry: @unchecked Sendable {
    private let lock = NSLock()
    private var _screenRect: CGRect?

    public init(screenRect: CGRect? = nil) {
        self._screenRect = screenRect
    }

    /// The latest known content rectangle, or nil before the first frame.
    ///
    /// Nil is meaningful and must not be papered over with a default: clicks
    /// that arrive before any frame has been delivered have nothing to map
    /// against, and inventing a rectangle would place them confidently in the
    /// wrong spot.
    public var screenRect: CGRect? {
        lock.lock()
        defer { lock.unlock() }
        return _screenRect
    }

    public func update(screenRect: CGRect) {
        lock.lock()
        _screenRect = screenRect
        lock.unlock()
    }

    /// The fraction for a click, against whatever the geometry is right now.
    ///
    /// Returns nil when the click is outside the content OR when no frame has
    /// arrived yet — both mean "this click has no position in the picture",
    /// which is exactly what the event log should record.
    public func fraction(ofScreenPoint point: CGPoint) -> CGPoint? {
        guard let rect = screenRect else { return nil }
        return ClickPosition.fraction(ofScreenPoint: point, inContent: rect)
    }
}
