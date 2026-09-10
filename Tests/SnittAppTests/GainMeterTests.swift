// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
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
