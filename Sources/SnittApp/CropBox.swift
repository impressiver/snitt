// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import CoreGraphics

/// Which part of a crop box a drag grabbed.
///
/// `inside` moves the whole box; every other case resizes by moving the edges
/// it names. `nil` from `CropBox.handle(at:in:)` means the drag started
/// somewhere else entirely, which the overlay reads as "draw a new box".
enum CropHandle: Equatable, CaseIterable {
    case topLeft, top, topRight
    case left, inside, right
    case bottomLeft, bottom, bottomRight
}

/// The arithmetic behind an adjustable crop rectangle.
///
/// Split out of `CropDragOverlay` for the same reason `CropGeometry` was: a
/// SwiftUI gesture cannot be tested, so anything that can be got wrong lives
/// here, pure, with both the box and its limit passed in.
///
/// Coordinates are top-left origin — SwiftUI's default space, and the same
/// convention `CropGeometry` and `CropRect` use. A y-flip here would put every
/// handle on the wrong side of the box while still passing any test written in
/// terms of "the top handle moves the top edge".
enum CropBox {
    /// How close a click must be to an edge to grab it, in points.
    ///
    /// Wide enough to hit with a mouse without care (a 1px stroke is not a
    /// target), narrow enough that a small box still has an interior to grab
    /// for moving — at 12pt a box must be 24pt across before `inside` is
    /// reachable at all, which the minimum below deliberately exceeds.
    static let handleTolerance: CGFloat = 12

    /// The smallest box a resize may produce, in points.
    ///
    /// Not zero: a box dragged to nothing is unrecoverable without leaving
    /// crop mode, because there is no longer anything on screen to grab.
    static let minimumSide: CGFloat = 32

    /// Which handle `point` grabs, or nil if it misses the box entirely.
    ///
    /// Corners beat edges beat the interior, because at a corner both edge
    /// bands overlap and resizing one axis when the user aimed at two is the
    /// more annoying wrong answer.
    static func handle(at point: CGPoint, in rect: CGRect,
                       tolerance: CGFloat = handleTolerance) -> CropHandle? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        // The band extends OUTSIDE the box as well as inside: an edge is a
        // line, and a person aiming at it lands on either side of it.
        guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return nil }

        let left = abs(point.x - rect.minX) <= tolerance
        let right = abs(point.x - rect.maxX) <= tolerance
        let top = abs(point.y - rect.minY) <= tolerance
        let bottom = abs(point.y - rect.maxY) <= tolerance

        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return rect.contains(point) ? .inside : nil
        }
    }

    /// The box `handle` produces when dragged by `translation` from `rect`.
    ///
    /// `rect` is the box as it was when the drag BEGAN, not the live one:
    /// SwiftUI reports a drag's translation cumulatively from its start, so
    /// applying it to the live box would compound it on every frame and the
    /// edge would race away from the pointer.
    ///
    /// Always returns a box inside `limit` and at least `minimum` on a side.
    /// Clamping rather than flipping when an edge is dragged past its
    /// opposite: a box that inverts under the pointer is disorienting, and
    /// the gesture that wants the other side is available by grabbing it.
    static func adjusted(_ rect: CGRect, handle: CropHandle, by translation: CGSize,
                         limit: CGRect, minimum: CGFloat = minimumSide) -> CGRect {
        guard limit.width > 0, limit.height > 0 else { return rect }

        if handle == .inside {
            // Moving never resizes, so a box pushed at the edge stops there
            // rather than being squashed against it.
            var moved = rect.offsetBy(dx: translation.width, dy: translation.height)
            moved.origin.x = moved.width >= limit.width
                ? limit.minX
                : min(max(moved.minX, limit.minX), limit.maxX - moved.width)
            moved.origin.y = moved.height >= limit.height
                ? limit.minY
                : min(max(moved.minY, limit.minY), limit.maxY - moved.height)
            return moved
        }

        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft:     minX += translation.width; minY += translation.height
        case .top:                                    minY += translation.height
        case .topRight:    maxX += translation.width; minY += translation.height
        case .left:        minX += translation.width
        case .right:       maxX += translation.width
        case .bottomLeft:  minX += translation.width; maxY += translation.height
        case .bottom:                                 maxY += translation.height
        case .bottomRight: maxX += translation.width; maxY += translation.height
        case .inside: break  // handled above
        }

        // Each handle moves at most ONE edge per axis, so clamping the moved
        // edge against the stationary one needs no second pass.
        let side = min(minimum, min(limit.width, limit.height))
        minX = min(max(minX, limit.minX), maxX - side)
        maxX = max(min(maxX, limit.maxX), minX + side)
        minY = min(max(minY, limit.minY), maxY - side)
        maxY = max(min(maxY, limit.maxY), minY + side)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A brand-new box between two points, clipped to `limit`.
    ///
    /// Returns nil when the drag expressed nothing usable — degenerate, or
    /// entirely outside the picture — which the caller must not confuse with
    /// "crop to nothing".
    static func box(from start: CGPoint, to end: CGPoint, limit: CGRect) -> CGRect? {
        let drawn = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                           width: abs(end.x - start.x), height: abs(end.y - start.y))
        let clipped = drawn.intersection(limit)
        guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else { return nil }
        return clipped
    }
}
