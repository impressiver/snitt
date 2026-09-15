// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import CoreGraphics
import SwiftUI
@testable import SnittApp

/// The transcript's word wrap, as arithmetic.
///
/// Reported as "the transcript layout is janky": phrases drew over the row
/// beneath them, one row ballooned to several times its content, and the
/// timestamp sat level with the LAST line of a wrapped phrase instead of the
/// first.
///
/// Three separate defects, and only one of them was the new lane rule. These
/// cover the two that had been in `WrappingLayout` from the start and were
/// invisible while every row was a single line.
struct WrappingLayoutTests {

    private func boxes(_ widths: [CGFloat], height: CGFloat = 20) -> [CGSize] {
        widths.map { CGSize(width: $0, height: height) }
    }

    /// The bottom of the lowest box placed.
    private func contentBottom(_ plan: (origins: [CGPoint], size: CGSize),
                               sizes: [CGSize]) -> CGFloat {
        zip(plan.origins, sizes).map { $0.y + $1.height }.max() ?? 0
    }

    private func contentRight(_ plan: (origins: [CGPoint], size: CGSize),
                              sizes: [CGSize]) -> CGFloat {
        zip(plan.origins, sizes).map { $0.x + $1.width }.max() ?? 0
    }

    @Test("The reported height contains every box it placed")
    func heightContainsItsContents() {
        // THE OVERFLOW. Measuring and placing were two copies of one loop, so
        // nothing forced them to agree — and when a sibling view changed the
        // width the stack granted after the measurement was taken, the row
        // reported a height for one wrap and drew a different one. The surplus
        // went over the row below.
        let sizes = boxes([60, 80, 55, 70, 90, 40, 65, 75, 50])
        for width in [100.0, 150.0, 200.0, 240.0, 301.0, 1000.0] {
            let plan = WrappingLayout.plan(sizes: sizes, width: width, spacing: 3)
            let bottom = contentBottom(plan, sizes: sizes)
            #expect(plan.size.height >= bottom - 0.001,
                    "at width \(width) the row reports \(plan.size.height)pt and draws down to \(bottom)pt")
        }
    }

    @Test("The reported width contains every box it placed")
    func widthContainsItsContents() {
        let sizes = boxes([60, 80, 55, 70])
        let plan = WrappingLayout.plan(sizes: sizes, width: 150, spacing: 3)
        #expect(plan.size.width >= contentRight(plan, sizes: sizes) - 0.001)
    }

    @Test("Boxes wrap when the line is full, and not before")
    func wrapsAtTheBoundary() {
        // Two 60pt boxes and 3pt of spacing need 123pt. At 123 they share a
        // line; at 122 they cannot.
        let sizes = boxes([60, 60])
        let together = WrappingLayout.plan(sizes: sizes, width: 123, spacing: 3)
        #expect(together.origins.map(\.y) == [0, 0], "they fit and were split anyway")

        let split = WrappingLayout.plan(sizes: sizes, width: 122, spacing: 3)
        #expect(split.origins[1].y > split.origins[0].y, "they do not fit and were not split")
        #expect(split.origins[1].x == 0, "the wrapped box did not return to the left edge")
    }

    @Test("A box wider than the whole row is placed, not dropped or looped over")
    func anOversizedBoxIsStillPlaced() {
        // A single long word at a narrow pane width. Wrapping "until it fits"
        // never terminates for this input, and skipping it loses a word from
        // the transcript — which reads as a recognition failure rather than a
        // layout one.
        let sizes = boxes([500, 40])
        let plan = WrappingLayout.plan(sizes: sizes, width: 100, spacing: 3)
        #expect(plan.origins.count == 2, "a box was dropped")
        #expect(plan.origins[0] == CGPoint(x: 0, y: 0))
        #expect(plan.origins[1].y > 0, "the next box stayed on the overflowing line")
    }

    @Test("Every box lands inside the row, left to right, top to bottom")
    func boxesNeverOverlap() {
        // Guards the placement itself: two boxes at the same origin satisfy
        // every size assertion above and render as one unreadable smear.
        let sizes = boxes([40, 55, 70, 35, 60, 45])
        let plan = WrappingLayout.plan(sizes: sizes, width: 160, spacing: 3)
        for (a, b) in zip(plan.origins, plan.origins.dropFirst()) {
            #expect(b.y > a.y || b.x > a.x, "two boxes were placed at the same spot")
        }
    }

    @Test("An unbounded proposal does not invent a wrap")
    func unboundedWidthStaysOnOneLine() {
        // `proposal.width` is nil while SwiftUI is asking "how big would you
        // like to be". The old answer substituted a literal 300, so an
        // unbounded measurement reported the height of a wrap that the row was
        // never going to perform.
        let sizes = boxes([200, 200, 200])
        let plan = WrappingLayout.plan(sizes: sizes, width: .infinity, spacing: 3)
        #expect(plan.origins.allSatisfy { $0.y == 0 }, "an unbounded row wrapped anyway")
        #expect(plan.size.height == 20)
    }

    @Test("Spacing is between boxes, never trailing the last one")
    func spacingDoesNotPadTheEnd() {
        // A trailing gap makes the row measure wider than it draws, which is
        // how a row that fits reports that it does not.
        let sizes = boxes([50, 50])
        let plan = WrappingLayout.plan(sizes: sizes, width: 1000, spacing: 10)
        #expect(plan.size.width == 110, "got \(plan.size.width), expected 50 + 10 + 50")
    }

    @Test("A line is as tall as its tallest box, whichever position it is in")
    func lineHeightIsTheTallestBox() {
        // Words differ in height — a low-confidence word is dimmed, an edited
        // one becomes a text field. A line sized to one particular box clips
        // the rest.
        //
        // BOTH ORDERS. The first version of this put the tall box last, so
        // `max(lineHeight, height)` and a plain `lineHeight = height` gave the
        // same answer and a mutant walked straight through — the twenty-eighth
        // time this project has caught a test asserting a property adjacent to
        // the one that mattered.
        let tallLast = [CGSize(width: 40, height: 20), CGSize(width: 40, height: 34)]
        #expect(WrappingLayout.plan(sizes: tallLast, width: 1000, spacing: 3).size.height == 34)

        let tallFirst = [CGSize(width: 40, height: 34), CGSize(width: 40, height: 20)]
        #expect(WrappingLayout.plan(sizes: tallFirst, width: 1000, spacing: 3).size.height == 34,
                "the line took its height from the last box rather than the tallest")
    }

    @Test("A wrapped row measures its widest LINE, not its running total")
    func wrappedWidthIsTheWidestLine() {
        // Two 50pt boxes that cannot share a 100pt row: each line is 50pt
        // wide, so the row is 50pt wide. Counting the trailing spacing, or the
        // position the cursor had reached, reports 60 — a row that claims to
        // be wider than anything drawn in it, which pushes its neighbours
        // around for nothing.
        //
        // The single-line case cannot see this: the wrap branch never runs, so
        // its copy of the width arithmetic is never executed at all.
        let sizes = boxes([50, 50])
        let plan = WrappingLayout.plan(sizes: sizes, width: 100, spacing: 10)
        #expect(plan.origins[1].y > 0, "the fixture did not wrap, so this proves nothing")
        #expect(plan.size.width == 50, "got \(plan.size.width), expected the widest line")
    }

    @Test("Nothing in, nothing out")
    func emptyIsEmpty() {
        let plan = WrappingLayout.plan(sizes: [], width: 200, spacing: 3)
        #expect(plan.origins.isEmpty)
        #expect(plan.size == .zero)
    }
}

/// Where the timestamp column ends up, in PIXELS.
///
/// The defect these exist for is invisible to every assertion about sizes: a
/// custom `Layout` that does not answer `explicitAlignment` still lays its own
/// words out perfectly, and `HStack(alignment: .firstTextBaseline)` simply
/// cannot find a baseline in it and falls back to the bottom edge. The
/// timestamp then sits level with the LAST line of a wrapped phrase.
///
/// It survived because it is invisible on a one-line row, and every row was
/// one line until narration started producing long ones.
///
/// Rendered rather than reasoned about, because `Layout.Subviews` cannot be
/// constructed outside SwiftUI's own layout pass — so the protocol method has
/// no seam a unit test can reach, and the only honest way to check it is to
/// look at the result.
@MainActor
struct TimestampAlignmentTests {

    /// The row, reduced to the two things whose alignment is in question.
    private func row(words: Int, width: CGFloat) throws -> NSBitmapImageRep {
        let view = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("0:01")
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(.white)
                .frame(width: 44, alignment: .leading)
            WrappingLayout(spacing: 3) {
                ForEach(0..<words, id: \.self) { index in
                    Text("word\(index)").font(.callout).foregroundStyle(.white)
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .background(Color.black)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        let data = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: data))
    }

    /// The rows of pixels carrying ink, within a horizontal slice.
    private func inkRows(_ bitmap: NSBitmapImageRep,
                         fromX: Int, toX: Int) -> ClosedRange<Int>? {
        var rows: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in fromX..<min(toX, bitmap.pixelsWide) {
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                if colour.brightnessComponent > 0.4 { rows.append(y); break }
            }
        }
        guard let low = rows.min(), let high = rows.max() else { return nil }
        return low...high
    }

    @Test("The timestamp sits level with the FIRST line of a wrapped phrase")
    func timestampTracksTheFirstLine() throws {
        // Twelve words at 220pt wrap to several lines. Without a baseline the
        // timestamp lands next to the last of them, several lines down — which
        // is what the screenshot showed.
        let bitmap = try row(words: 12, width: 220)
        let stamp = try #require(inkRows(bitmap, fromX: 0, toX: 40),
                                 "the timestamp did not render")
        let words = try #require(inkRows(bitmap, fromX: 52, toX: 220),
                                 "the words did not render")
        try #require(bitmap.pixelsHigh > 30, "the phrase did not wrap, so this proves nothing")

        // The timestamp's ink is in the top line's band, not the bottom's.
        let firstLineBottom = words.lowerBound + (bitmap.pixelsHigh / 4)
        #expect(stamp.lowerBound >= words.lowerBound - 4,
                "the timestamp floats above the text entirely")
        let height = bitmap.pixelsHigh
        #expect(stamp.upperBound <= firstLineBottom,
                "the timestamp is at rows \(stamp) of a \(height)pt row: it has sunk to a later line")
    }

    @Test("A one-line row is unchanged")
    func oneLineRowIsUnaffected() throws {
        // The case that always looked right, and must keep looking right: the
        // fix must not move the timestamp on the rows where the fallback
        // happened to agree with the baseline.
        let bitmap = try row(words: 2, width: 220)
        let stamp = try #require(inkRows(bitmap, fromX: 0, toX: 40))
        let words = try #require(inkRows(bitmap, fromX: 52, toX: 220))
        // Both on the one line, overlapping vertically.
        #expect(stamp.overlaps(words), "timestamp at \(stamp), words at \(words)")
    }

    @Test("A wrapped row is taller than a one-line row, and does not overflow it")
    func wrappedRowsGrow() throws {
        // The row-height half of the report: a phrase that wraps must make its
        // row taller. When it did not, the surplus drew over the row beneath.
        let short = try row(words: 2, width: 220)
        let long = try row(words: 12, width: 220)
        #expect(long.pixelsHigh > short.pixelsHigh,
                "a twelve-word phrase took \(long.pixelsHigh)pt, the same as two words")

        // And every drawn pixel is inside the reported height — nothing is
        // clipped at the bottom, which is the same defect seen from inside.
        let words = try #require(inkRows(long, fromX: 52, toX: 220))
        #expect(words.upperBound < long.pixelsHigh,
                "the phrase draws to row \(words.upperBound) of \(long.pixelsHigh)")
    }
}
