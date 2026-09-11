// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import CoreGraphics
@testable import SnittCapture

/// Mapping a desktop click into the recorded picture (D64).
///
/// Every test here is asymmetric on purpose. A fixture centred in its content
/// rect, or square, or at the origin, passes against a transposed mapping, a
/// flipped one, and one that forgot to subtract the origin — the three
/// plausible wrong implementations. So the content rect is offset, non-square,
/// and every asserted point is off-centre in both axes.
struct ClickPositionTests {

    /// Offset origin and a 2:1 aspect, so x and y can never be swapped
    /// undetected.
    private let content = CGRect(x: 100, y: 50, width: 800, height: 400)

    @Test("A click maps to its fraction of the content, origin subtracted")
    func mapsToFraction() throws {
        // Quarter across, three-quarters down — distinct values in each axis,
        // and neither is 0.5, so a transposition changes the answer.
        let point = CGPoint(x: 100 + 200, y: 50 + 300)
        let f = try #require(ClickPosition.fraction(ofScreenPoint: point, inContent: content))
        #expect(abs(f.x - 0.25) < 1e-9, "x was \(f.x)")
        #expect(abs(f.y - 0.75) < 1e-9, "y was \(f.y)")
    }

    @Test("The content's own origin is the zero point, not the desktop's")
    func originIsSubtracted() throws {
        // The discriminating case for "forgot to subtract the origin", which is
        // the single most likely mistake here and is invisible whenever the
        // content happens to start at (0, 0) — as it does for a full-screen
        // capture on the main display, which is exactly the fixture someone
        // would reach for.
        let f = try #require(ClickPosition.fraction(ofScreenPoint: CGPoint(x: 100, y: 50),
                                                    inContent: content))
        #expect(f == CGPoint(x: 0, y: 0))
    }

    @Test("A click outside the content has no position rather than a clamped one")
    func outsideIsNil() {
        // Clamping would be worse than nil: a click on another display would
        // draw a ring pinned to the nearest edge of this recording, which reads
        // as a real click that happened there. Each case moves ONE axis out of
        // range so a check that only tested the other still fails.
        let outside = [
            CGPoint(x: 99, y: 200),    // left of content
            CGPoint(x: 901, y: 200),   // right of content
            CGPoint(x: 300, y: 49),    // above content
            CGPoint(x: 300, y: 451),   // below content
        ]
        for p in outside {
            #expect(ClickPosition.fraction(ofScreenPoint: p, inContent: content) == nil,
                    "\(p) mapped to a position despite being outside the content")
        }
    }

    @Test("The far edge belongs to what is beyond it, not to the last pixel")
    func farEdgeIsExcluded() {
        // A fraction of exactly 1.0 multiplies out to one past the last pixel.
        // The near edge is inside, the far edge is not — asserted together
        // because a test that only checked one would pass against a mapping
        // that used a closed range on both.
        #expect(ClickPosition.fraction(ofScreenPoint: CGPoint(x: 100, y: 50),
                                       inContent: content) != nil)
        #expect(ClickPosition.fraction(ofScreenPoint: CGPoint(x: 900, y: 200),
                                       inContent: content) == nil)
        #expect(ClickPosition.fraction(ofScreenPoint: CGPoint(x: 300, y: 450),
                                       inContent: content) == nil)
    }

    @Test("A degenerate content rect yields no position, not an infinite one")
    func degenerateRectIsNil() {
        // Division by a zero width gives ±infinity, or NaN when the click is
        // exactly on the edge, and either would survive to a draw call as a
        // ring at an absurd coordinate. No separate guard produces this — the
        // half-open range check rejects NaN and both infinities — so this pins
        // the behaviour rather than a particular way of getting it.
        let flat = CGRect(x: 0, y: 0, width: 0, height: 400)
        #expect(ClickPosition.fraction(ofScreenPoint: .zero, inContent: flat) == nil)
        let thin = CGRect(x: 0, y: 0, width: 800, height: 0)
        #expect(ClickPosition.fraction(ofScreenPoint: .zero, inContent: thin) == nil)
    }

    @Test("Y is measured downward — both inputs are top-left origin")
    func yIsTopLeftOrigin() throws {
        // The load-bearing convention, pinned so a future flip fails here
        // rather than in the exported pixels. A click near the TOP of the
        // content must produce a SMALL y. Under a bottom-left reading this
        // returns ~0.9 instead, and nothing else in the suite would notice.
        let nearTop = CGPoint(x: 500, y: 50 + 40)
        let f = try #require(ClickPosition.fraction(ofScreenPoint: nearTop, inContent: content))
        #expect(f.y < 0.2, "y was \(f.y) for a click near the top edge")
    }
}

/// The geometry the event tap reads while frames are still arriving.
struct CapturedContentGeometryTests {

    @Test("Before any frame arrives a click has no position")
    func noFrameYetMeansNoPosition() {
        // Not a default rectangle. A click during the gap between the tap
        // starting and the first frame landing has genuinely nothing to map
        // against, and inventing a rect would place it confidently and wrongly.
        let geometry = CapturedContentGeometry()
        #expect(geometry.screenRect == nil)
        // The click sits at the ORIGIN, which is inside any rectangle a
        // defaulting implementation would invent — they are all anchored at
        // (0, 0). An earlier version of this test used (10, 10) and passed
        // against a default of 1×1, because that point fell outside the fake
        // rect as well: the fixture, not the assertion, was deciding the
        // answer. Verified against a mutant that defaults rather than
        // returning nil.
        #expect(geometry.fraction(ofScreenPoint: .zero) == nil,
                "a click before any frame was given a position anyway")
        #expect(geometry.fraction(ofScreenPoint: CGPoint(x: 10, y: 10)) == nil)
    }

    @Test("A click maps against the LATEST frame, not the first")
    func windowMovesMidRecording() throws {
        // The whole reason this is mutable state rather than a constant: drag
        // the recorded window and every later click maps against a rectangle
        // that moved. An implementation that captured the rect once at start
        // passes every other test in this file and fails this one.
        let geometry = CapturedContentGeometry(
            screenRect: CGRect(x: 0, y: 0, width: 400, height: 400))
        let click = CGPoint(x: 300, y: 100)

        let before = try #require(geometry.fraction(ofScreenPoint: click))
        #expect(abs(before.x - 0.75) < 1e-9)

        // The window moves right by 200pt; the same desktop point is now only
        // a quarter of the way across it.
        geometry.update(screenRect: CGRect(x: 200, y: 0, width: 400, height: 400))
        let after = try #require(geometry.fraction(ofScreenPoint: click))
        #expect(abs(after.x - 0.25) < 1e-9, "x was \(after.x) after the window moved")
    }

    @Test("A click that the window moved away from stops having a position")
    func clickOutsideAfterMoveIsNil() {
        // The same event, the same coordinates, a different answer — because
        // the picture moved. Records that "outside" is recomputed per click
        // rather than decided once.
        let geometry = CapturedContentGeometry(
            screenRect: CGRect(x: 0, y: 0, width: 400, height: 400))
        let click = CGPoint(x: 100, y: 100)
        #expect(geometry.fraction(ofScreenPoint: click) != nil)
        geometry.update(screenRect: CGRect(x: 800, y: 0, width: 400, height: 400))
        #expect(geometry.fraction(ofScreenPoint: click) == nil)
    }
}
