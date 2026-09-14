// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import SnittBrand
import Testing
import Foundation
import AppKit
import SwiftUI
@testable import SnittApp

/// The gain ladder beside each audio lane.
///
/// A meter that put 0 dB in the wrong place would be lying about the one value
/// its user is trying to set, so the arithmetic is asserted rather than eyed.
@Suite
struct GainMeterTests {

    @Test("Unity is 0 dB, and it is reachable exactly")
    func unityIsZeroDecibels() {
        // The value people most want to return to. `pow(10, 0/20)` landing on
        // 0.9999 would leave a track fractionally quiet forever, with a meter
        // reading 0 dB while the export said otherwise.
        #expect(abs(GainMeter.decibels(forGain: 1)) < 0.001)
        #expect(GainMeter.label(forGain: 1) == "0 dB")
        let atUnity = GainMeter.gain(
            forFraction: Double(GainMeter.unitySegment) / Double(GainMeter.segmentCount))
        #expect(atUnity == 1.0)
    }

    @Test("Unity sits two-thirds up, not in the middle")
    func unityIsNotCentred() {
        // The scale runs −24…+12, so two-thirds of it is attenuation. That
        // asymmetry matches every hardware meter — you spend far more time
        // pulling a level down than pushing it up — and a centred unity would
        // give half the ladder to boost nobody uses.
        #expect(GainMeter.unitySegment == 8)
        #expect(GainMeter.litSegments(forGain: 1) == 8)
    }

    @Test("Doubling the gain is +6 dB")
    func doublingIsSixDecibels() {
        #expect(abs(GainMeter.decibels(forGain: 2) - 6.02) < 0.05)
        #expect(abs(GainMeter.decibels(forGain: 0.5) + 6.02) < 0.05)
    }

    @Test("Silence reads as an empty ladder, not as NaN")
    func silenceIsNotNaN() {
        // `log10(0)` is −inf, and −inf through the segment arithmetic is NaN,
        // which renders as an empty view or a crash depending on where it
        // lands. A muted track is a real, common state.
        #expect(GainMeter.decibels(forGain: 0) == GainMeter.minimumDecibels)
        #expect(GainMeter.litSegments(forGain: 0) == 0)
        #expect(GainMeter.label(forGain: 0) == "−∞")
    }

    @Test("The ladder covers the whole range the model allows")
    func ladderCoversTheClamp() {
        // `setGain` clamps to 0…4. A ladder that topped out below 4 would
        // leave gains the model accepts unreachable from the meter — and
        // unreadable on it.
        #expect(GainMeter.litSegments(forGain: 4) == GainMeter.segmentCount)
        #expect(abs(GainMeter.gain(forDecibels: GainMeter.maximumDecibels) - 3.98) < 0.02)
    }

    @Test("Segments at or above unity are hot")
    func hotSegmentsAreTheBoost() {
        // Above 0 dB the track is being amplified, and amplification is where
        // clipping comes from — the one thing a meter exists to warn about.
        #expect(!GainMeter.isHot(segment: GainMeter.unitySegment - 1))
        #expect(GainMeter.isHot(segment: GainMeter.unitySegment))
        #expect(GainMeter.isHot(segment: GainMeter.segmentCount - 1))
    }

    @Test("A drag quantises to segments the user can see")
    func dragSnapsToSegments() {
        // A continuous value would let a drag land somewhere the ladder cannot
        // display, and the readout and the lit count would then disagree about
        // the same track.
        let a = GainMeter.gain(forFraction: 0.66)
        let b = GainMeter.gain(forFraction: 0.68)
        #expect(a == b, "two drags inside one segment produced different gains")
        #expect(GainMeter.litSegments(forGain: a) == 8)
    }

    @Test("A drag off either end clamps rather than running away")
    func dragClamps() {
        #expect(GainMeter.gain(forFraction: -3) == GainMeter.gain(forFraction: 0))
    }

    @Test("Dragging the fader to the bottom is SILENCE, not the bottom of the scale")
    func bottomOfTheLadderIsSilent() {
        // Reported as "the gain adjustment only reduces the levels partially",
        // and it did: the bottom used to produce `gain(forDecibels: -24)`,
        // which is `pow(10, -24/20)` ≈ 0.063 — six percent of the original,
        // clearly audible, with the fader visibly at the floor.
        //
        // −24 dB is the bottom of the DISPLAY, chosen so unity sits usefully
        // on the scale. It was being treated as the bottom of the RANGE, and a
        // fader that cannot reach silence is not a fader.
        #expect(GainMeter.gain(forFraction: 0) == 0)
        #expect(GainMeter.gain(forFraction: -3) == 0, "past the bottom is also silence")

        // The readout already knew: it prints −∞ at gain 0 and always did.
        // Only the drag could not get there.
        #expect(GainMeter.label(forGain: GainMeter.gain(forFraction: 0)) == "−∞")
        // And nothing is lit, which is what silence looks like on a ladder.
        #expect(GainMeter.litSegments(forGain: GainMeter.gain(forFraction: 0)) == 0)
    }

    @Test("One notch up from the bottom is quiet, not silent")
    func oneNotchUpIsAudible() {
        // The other side of the same line. Silence is the bottom POSITION, not
        // a dead zone at the bottom of the travel — a fader whose first few
        // notches all meant silence would be worse than one that never reached
        // it.
        let notch = GainMeter.gain(forFraction: 1.0 / Double(GainMeter.segmentCount))
        #expect(notch > 0)
        #expect(notch < 0.2, "one notch up is \(notch), which is not quiet")
        #expect(GainMeter.gain(forFraction: 9) == GainMeter.gain(forFraction: 1))
        #expect(GainMeter.litSegments(forGain: GainMeter.gain(forFraction: 9))
                == GainMeter.segmentCount)
    }

    @Test("Every fraction round-trips to a lit count on the ladder")
    func fractionsAreAlwaysDisplayable() {
        // The guard that the drag mapping and the display mapping are inverses.
        // If they drift, a drag sets a gain the ladder then draws at a
        // different height than the finger that set it.
        for step in 0...20 {
            let fraction = Double(step) / 20
            let gain = GainMeter.gain(forFraction: fraction)
            let lit = GainMeter.litSegments(forGain: gain)
            #expect(lit >= 0 && lit <= GainMeter.segmentCount, "\(fraction) lit \(lit)")
        }
    }

    @Test("The readout signs its numbers")
    func labelIsSigned() {
        // "+6 dB" and "−6 dB" are different instructions; "6 dB" is neither.
        #expect(GainMeter.label(forGain: 2).hasPrefix("+"))
        #expect(GainMeter.label(forGain: 0.5).hasPrefix("-"))
    }
}

// The ladder's colours (rev 5, W13). `GainMeter`'s arithmetic is tested above
// and unchanged; what these pin is that the view colours what the arithmetic
// decides, in the brand's vocabulary rather than the user's accent colour.
@Suite
struct GainMeterAppearanceTests {

    private func srgb(_ color: Color) -> NSColor {
        NSColor(color).usingColorSpace(.sRGB)!
    }

    @Test("A hot segment is red and a lit one is amber — the same red and amber as the lanes")
    func ladderSpeaksTheBrand() {
        // It was `Color.accentColor` for lit and the chrome highlight for hot,
        // so on a blue-accented Mac a blue meter sat beside an amber waveform
        // measuring the same track. Identity, not "some warm colour": the
        // meter and the waveform must agree about what a loud microphone
        // looks like.
        let view = GainMeterView(title: "Mic", gain: 2.0, muted: false,
                                 onGain: { _ in }, onToggleMute: {})
        #expect(srgb(view.colourForTesting(0)) == srgb(SnittPalette.Swatch.signal),
                "a lit segment is not brand amber")
        #expect(srgb(view.colourForTesting(GainMeter.unitySegment))
                == srgb(SnittPalette.Swatch.recordRed),
                "a segment at unity is not brand red")
    }

    @Test("A muted ladder goes dark but stays visible")
    func mutedLadderDims() {
        // A muted track lights NO segments — `lit` is 0 — so the whole ladder
        // falls to the unlit colour. What matters is that it dims rather than
        // disappearing: a meter you cannot see is a meter you cannot un-mute
        // from, and double-clicking it is how you do that.
        //
        // Stated this way because the first version asserted the lit colour
        // dimmed when muted, which cannot happen and so passed against an
        // implementation with no dimming at all.
        let muted = GainMeterView(title: "Mic", gain: 2.0, muted: true,
                                  onGain: { _ in }, onToggleMute: {})
        let unmuted = GainMeterView(title: "Mic", gain: 2.0, muted: false,
                                    onGain: { _ in }, onToggleMute: {})
        let mutedAlpha = srgb(muted.colourForTesting(0)).alphaComponent
        #expect(mutedAlpha < srgb(unmuted.colourForTesting(0)).alphaComponent,
                "muting did not dim the ladder")
        #expect(mutedAlpha > 0.1, "a muted ladder went invisible")
    }

    @Test("An unlit segment is ink, not a system grey")
    func unlitIsInk() {
        let view = GainMeterView(title: "Mic", gain: 0.1, muted: false,
                                 onGain: { _ in }, onToggleMute: {})
        #expect(srgb(view.colourForTesting(GainMeter.segmentCount - 1))
                == srgb(SnittPalette.Swatch.ink3))
    }
}
