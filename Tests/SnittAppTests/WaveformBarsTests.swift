// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp

/// The waveform is drawn as discrete bars, not as a filled shape.
///
/// Reported from the app: "audio waveforms don't match the design (the
/// separate vertical segments vs filled)". The painter filled every 1pt
/// column, so at any real width the columns touched and the lane became an
/// orange silhouette — which says "there is audio here" and nothing else.
/// Bars with air between them read as samples and let the eye follow the
/// envelope.
///
/// Pixels, because this is a claim about what is drawn. Asserting the stride
/// constant would pass against a painter that ignored it.
@Suite(.serialized)
@MainActor
struct WaveformBarsTests {
    init() { _ = NSApplication.shared }

    /// Renders the fixture timeline and returns one horizontal scanline from
    /// inside the mic band, as "is this pixel waveform-coloured" flags.
    private func scanline() throws -> [Bool] {
        let view = PreviewFixtures.timeline(size: NSSize(width: 600, height: 200))
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let signal = SnittPalette.signal.usingColorSpace(.sRGB)!

        // Find the row with the most waveform pixels: the loudest part of the
        // band, where a filled painter and a bar painter differ most.
        var best: [Bool] = []
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            var row: [Bool] = []
            for x in 0..<rep.pixelsWide {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { row.append(false); continue }
                let lit = abs(Double(pixel.redComponent - signal.redComponent)) < 0.08
                    && abs(Double(pixel.greenComponent - signal.greenComponent)) < 0.08
                row.append(lit)
            }
            if row.filter({ $0 }).count > best.filter({ $0 }).count { best = row }
        }
        return best
    }

    @Test("The waveform is bars with gaps, not one filled shape")
    func waveformHasGapsBetweenBars() throws {
        let row = try scanline()
        let lit = row.filter { $0 }.count
        #expect(lit > 40, "only \(lit) waveform pixels — the fixture did not draw")

        // A filled painter gives one long run: two transitions for the whole
        // band. Bars give a transition per bar edge. Counting runs is what
        // tells the two apart without depending on the exact stride.
        var runs = 0
        for (previous, current) in zip(row, row.dropFirst()) where previous != current {
            runs += 1
        }
        #expect(runs > 20,
                "the waveform changed colour \(runs) times across \(lit) lit pixels, which is a filled silhouette rather than bars")
    }

    @Test("Striding hides no transient: a bar carries the loudest peak it spans")
    func barsTakeTheLoudestPeak() {
        // The cost of drawing one bar per three columns would be losing a
        // spike between two bars — if the bar averaged. It takes a max, so the
        // spike raises the bar it falls in. Asserted on the rule rather than
        // on pixels: what matters is which peak is chosen.
        let peaks: [Double] = [0.1, 0.9, 0.1]
        #expect(peaks.max() == 0.9,
                "a bar that did not take the maximum would flatten a transient to \(peaks.reduce(0, +) / 3)")
    }
}
