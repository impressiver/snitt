import CoreGraphics
import Testing
@testable import SnittApp

/// The crop box is adjustable before it is committed.
///
/// The gesture this replaces applied a crop on mouse-up, which made cropping a
/// single unrepeatable act: the only correction was undo plus a fresh drag,
/// and the box being aimed at was already off the screen. Everything that can
/// be got wrong about moving and resizing it lives in `CropBox`, pure, because
/// a SwiftUI drag cannot be tested.
///
/// Coordinates are TOP-LEFT origin throughout. A y-flip is the failure mode
/// that passes every arithmetic test written as "the top handle moves the top
/// edge" while putting every handle on the wrong side of the box, so the
/// direction tests below assert signs, not magnitudes.
@Suite
struct CropBoxTests {
    private let limit = CGRect(x: 100, y: 50, width: 400, height: 300)
    private let box = CGRect(x: 200, y: 100, width: 200, height: 150)

    // MARK: - Which handle a click grabs

    @Test("Every handle is reachable at its own position")
    func everyHandleIsReachable() {
        // A table rather than eight tests, because the failure this guards is
        // one entry of a switch copied from its neighbour and not edited —
        // which a test of only two handles cannot see.
        let cases: [(CGPoint, CropHandle)] = [
            (CGPoint(x: box.minX, y: box.minY), .topLeft),
            (CGPoint(x: box.midX, y: box.minY), .top),
            (CGPoint(x: box.maxX, y: box.minY), .topRight),
            (CGPoint(x: box.minX, y: box.midY), .left),
            (CGPoint(x: box.maxX, y: box.midY), .right),
            (CGPoint(x: box.minX, y: box.maxY), .bottomLeft),
            (CGPoint(x: box.midX, y: box.maxY), .bottom),
            (CGPoint(x: box.maxX, y: box.maxY), .bottomRight),
            (CGPoint(x: box.midX, y: box.midY), .inside),
        ]
        for (point, expected) in cases {
            #expect(CropBox.handle(at: point, in: box) == expected,
                    "\(point) should grab \(expected)")
        }
    }

    @Test("A corner grabs the corner, not one of the edges that meet there")
    func cornerBeatsEdge() {
        // At a corner both edge bands are satisfied. Returning `.top` there
        // resizes one axis when the user aimed at two, and the box refuses to
        // follow the pointer diagonally — the most common way this is got
        // wrong, because a naive chain of `if` tests hits the edge case first.
        #expect(CropBox.handle(at: CGPoint(x: box.minX + 1, y: box.minY + 1), in: box) == .topLeft)
        #expect(CropBox.handle(at: CGPoint(x: box.maxX - 1, y: box.maxY - 1), in: box) == .bottomRight)
    }

    @Test("The grab band reaches outside the box, not only inside it")
    func bandReachesOutside() {
        // An edge is a one-pixel line. A person aiming at it lands on either
        // side, and a hit test that only looks inward makes the box feel
        // like it is dodging the pointer.
        let justOutside = CGPoint(x: box.minX - 4, y: box.midY)
        #expect(CropBox.handle(at: justOutside, in: box) == .left)
    }

    @Test("A click well away from the box grabs nothing")
    func missReturnsNil() {
        // nil is what tells the overlay to start drawing a REPLACEMENT box.
        // Returning `.inside` for a miss would make it impossible to redraw.
        #expect(CropBox.handle(at: CGPoint(x: box.maxX + 60, y: box.midY), in: box) == nil)
        #expect(CropBox.handle(at: CGPoint(x: box.midX, y: box.minY - 60), in: box) == nil)
    }

    // MARK: - Resizing

    @Test("Dragging one edge moves that edge and leaves the other three")
    func oneEdgeMovesAlone() {
        // The wrong implementation this rules out is offsetting the whole
        // rect for every handle — which looks correct while dragging the
        // right edge of a box you are not watching closely, because the box
        // does move.
        let result = CropBox.adjusted(box, handle: .right,
                                      by: CGSize(width: 40, height: 0), limit: limit)
        #expect(result.maxX == box.maxX + 40)
        #expect(result.minX == box.minX, "the left edge moved too")
        #expect(result.minY == box.minY)
        #expect(result.maxY == box.maxY)
    }

    @Test("Top and bottom handles move in top-left-origin directions")
    func verticalHandlesRespectTheOrigin() {
        // Negative dy is UP on screen. A y-flip here grows the box downward
        // when the user drags up, which is invisible in any test that only
        // checks that the height changed.
        let up = CropBox.adjusted(box, handle: .top,
                                  by: CGSize(width: 0, height: -30), limit: limit)
        #expect(up.minY == box.minY - 30)
        #expect(up.height == box.height + 30)

        let down = CropBox.adjusted(box, handle: .bottom,
                                    by: CGSize(width: 0, height: 30), limit: limit)
        #expect(down.maxY == box.maxY + 30)
        #expect(down.minY == box.minY)
    }

    @Test("A corner moves both of its edges")
    func cornerMovesBothEdges() {
        let result = CropBox.adjusted(box, handle: .bottomRight,
                                      by: CGSize(width: 25, height: 15), limit: limit)
        #expect(result.maxX == box.maxX + 25)
        #expect(result.maxY == box.maxY + 15)
        #expect(result.origin == box.origin, "a corner drag moved the opposite corner")
    }

    @Test("A resize stops at the edge of the picture")
    func resizeClampsToTheLimit() {
        // Past the picture there is nothing to keep. Letting the box run out
        // there produces a crop the renderer fills with black.
        let result = CropBox.adjusted(box, handle: .right,
                                      by: CGSize(width: 5000, height: 0), limit: limit)
        #expect(result.maxX == limit.maxX)
    }

    @Test("An edge dragged past its opposite stops at the minimum, it does not invert")
    func resizeStopsAtTheMinimum() {
        // Inverting under the pointer is disorienting, and a zero-width box
        // is unrecoverable: there is nothing left on screen to grab.
        let result = CropBox.adjusted(box, handle: .left,
                                      by: CGSize(width: 5000, height: 0), limit: limit)
        #expect(result.width == CropBox.minimumSide)
        #expect(result.maxX == box.maxX, "the stationary edge moved")
        #expect(result.minX < result.maxX, "the box inverted")
    }

    @Test("The minimum never exceeds the picture it must fit inside")
    func minimumYieldsToATinyPicture() {
        // A very small preview — a narrow window, or a pillarboxed portrait
        // recording — has less room than the minimum asks for. Clamping to
        // the minimum anyway produces a box larger than the picture, which
        // then normalizes past 1.0.
        let tiny = CGRect(x: 0, y: 0, width: 20, height: 18)
        let result = CropBox.adjusted(tiny, handle: .left,
                                      by: CGSize(width: 500, height: 0), limit: tiny)
        #expect(result.minX >= tiny.minX)
        #expect(result.maxX <= tiny.maxX)
    }

    // MARK: - Moving

    @Test("Moving the box changes where it is, not how big it is")
    func moveKeepsTheSize() {
        let result = CropBox.adjusted(box, handle: .inside,
                                      by: CGSize(width: 30, height: -20), limit: limit)
        #expect(result.size == box.size)
        #expect(result.minX == box.minX + 30)
        #expect(result.minY == box.minY - 20)
    }

    @Test("A box pushed at the edge stops there rather than being squashed")
    func moveClampsWithoutShrinking() {
        // The plausible wrong implementation clamps minX and maxX
        // independently, which silently narrows the box every time somebody
        // shoves it into a corner — and they never get the size back.
        let result = CropBox.adjusted(box, handle: .inside,
                                      by: CGSize(width: 5000, height: 5000), limit: limit)
        #expect(result.size == box.size, "the box was resized by a move")
        #expect(result.maxX == limit.maxX)
        #expect(result.maxY == limit.maxY)
    }

    @Test("A box larger than the picture is parked at the origin, not pushed off it")
    func oversizedBoxDoesNotEscape() {
        // Reachable when the window shrinks under a placed box. The
        // clamp-to-`maxX - width` arithmetic goes NEGATIVE here and would
        // move the box off the left edge.
        let oversized = CGRect(x: 0, y: 0, width: 900, height: 700)
        let result = CropBox.adjusted(oversized, handle: .inside,
                                      by: CGSize(width: 50, height: 50), limit: limit)
        #expect(result.minX == limit.minX)
        #expect(result.minY == limit.minY)
    }

    // MARK: - Drawing a replacement

    @Test("A backwards drag draws the same box as a forwards one")
    func backwardsDragNormalizes() {
        // Dragging up-and-left is as natural as down-and-right, and a raw
        // width/height subtraction yields a negative-size rect that draws as
        // nothing.
        let forwards = CropBox.box(from: CGPoint(x: 200, y: 100),
                                   to: CGPoint(x: 300, y: 200), limit: limit)
        let backwards = CropBox.box(from: CGPoint(x: 300, y: 200),
                                    to: CGPoint(x: 200, y: 100), limit: limit)
        #expect(forwards == backwards)
        #expect(forwards?.width == 100)
    }

    @Test("A new box is clipped to the picture")
    func newBoxIsClipped() {
        let result = CropBox.box(from: CGPoint(x: 300, y: 200),
                                 to: CGPoint(x: 9000, y: 9000), limit: limit)
        #expect(result?.maxX == limit.maxX)
        #expect(result?.maxY == limit.maxY)
    }

    @Test("A drag that expresses nothing returns nil rather than an empty crop")
    func degenerateDragIsRefused() {
        // nil means "no crop was expressed", which the caller must not
        // confuse with "crop to nothing" — the second discards the recording.
        #expect(CropBox.box(from: CGPoint(x: 200, y: 100),
                            to: CGPoint(x: 200, y: 100), limit: limit) == nil)
        #expect(CropBox.box(from: CGPoint(x: 900, y: 900),
                            to: CGPoint(x: 950, y: 950), limit: limit) == nil)
    }
}
