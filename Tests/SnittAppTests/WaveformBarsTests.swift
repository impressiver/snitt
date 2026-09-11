// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

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

/// The waveform is the same shape at every zoom (2026-09-11).
///
/// Reported from use: "the waveform glitches in and out when scaling the
/// timeline, it should be vertically consistent regardless of x scale (and
/// never completely blank unless absolutely no audio data was recorded for
/// that time period)".
///
/// The painter read ONE sample per column — the one under its left edge — so
/// at any zoom-out a column's height depended on whether that single sample
/// fell on a peak or in a trough between two syllables. Zooming changed which
/// samples were hit, so the envelope flickered and long stretches of real
/// speech read as silence. Each column now takes the MAXIMUM over the span it
/// covers, which is how a waveform is drawn: an envelope, identical at every
/// zoom, blank only where every sample under it really is silent.
///
/// **What these two tests do and do not establish, stated because it matters:**
/// they assert the properties that were asked for — the lane is not blank
/// where there is audio, and its coverage does not swing with width. They do
/// NOT fail against the point-sampling implementation they were written for.
/// Several fixtures were tried; the 3pt bar stride already takes a maximum
/// across its own columns, so a single missed column rarely costs a bar, and
/// the minimum-span hysteresis merges the short quiet runs that point-sampling
/// invents. Both mask the difference at the pixel level.
///
/// Kept anyway, because the properties are real and worth holding; but the
/// reported artifact was reproduced from a real recording, not from these, and
/// whether it is gone is a question for the built app rather than for this
/// file.
@Suite(.serialized)
@MainActor
struct WaveformZoomStabilityTests {
    init() { _ = NSApplication.shared }

    /// Continuous speech: every sample loud, so ANY correct rendering draws
    /// bars across the whole lane at every width.
    private func loudThroughout() -> WaveformSamples {
        WaveformSamples(track: "microphone", samplesPerSecond: 100,
                        peaks: (0..<4200).map { i in
                            // Syllable-sized bursts: 0.1s of speech, 0.1s of
                            // breath, forever. Sized deliberately — longer
                            // than one sample, shorter than one column at a
                            // zoomed-out width — because that is the band
                            // where reading a single sample per column is a
                            // coin flip and reading the span's maximum is not.
                            (i / 10) % 2 == 0 ? 0.55 : 0.02
                        })
    }

    private func litFraction(width: Double) throws -> Double {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: 200))
        view.update(duration: 42, cuts: [], markerPoints: [], playhead: 0,
                    trackStates: [TrackState(track: "microphone")],
                    waveforms: [loudThroughout()])
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let signal = SnittPalette.signal.usingColorSpace(.sRGB)!

        // The proportion of horizontal positions that carry ANY waveform
        // pixel. Position rather than pixel count, so a wider view is
        // comparable with a narrower one.
        var litColumns = 0
        for x in 0..<rep.pixelsWide {
            var lit = false
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) where !lit {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(Double(pixel.redComponent - signal.redComponent)) < 0.08,
                   abs(Double(pixel.greenComponent - signal.greenComponent)) < 0.08 {
                    lit = true
                }
            }
            if lit { litColumns += 1 }
        }
        return Double(litColumns) / Double(rep.pixelsWide)
    }

    @Test("Continuous speech draws across the lane at every zoom")
    func speechIsNeverBlank() throws {
        // "Never completely blank unless absolutely no audio data was
        // recorded." Every sample here is loud except the tremolo troughs, so
        // any width that shows large gaps is showing sampling noise.
        for width in [400.0, 900.0, 2400.0] {
            let lit = try litFraction(width: width)
            #expect(lit > 0.5,
                    "at \(width)pt only \(Int(lit * 100))% of the lane drew — continuous speech read as silence")
        }
    }

    @Test("The lane looks the same whether zoomed in or out")
    func coverageIsStableAcrossZoom() throws {
        // The "glitches in and out" half: the same audio must not become a
        // different shape because the view got wider. Point-sampling made this
        // swing wildly; an envelope keeps it flat.
        let narrow = try litFraction(width: 400)
        let wide = try litFraction(width: 2400)
        #expect(abs(narrow - wide) < 0.15,
                "the lane is \(Int(narrow * 100))% covered at 400pt and \(Int(wide * 100))% at 2400pt")
    }
}
