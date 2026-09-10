// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// The reading on a track's gain meter.
///
/// Pure, because everything worth getting right here is arithmetic: where
/// unity sits, which segments are hot, and how a drag maps back to a gain. A
/// meter that put 0 dB in the wrong place would be lying about the one value
/// its user is trying to set.
public enum GainMeter {

    /// Segments in the ladder. Twelve at 3 dB each spans −24…+12, which puts
    /// the whole usable range of `setGain`'s 0…4 clamp on the scale.
    public static let segmentCount = 12
    public static let minimumDecibels: Double = -24
    public static let maximumDecibels: Double = 12

    /// Gain as decibels, floored at `minimumDecibels`.
    ///
    /// Silence needs no special case: `log10(0)` is `-inf`, and
    /// `min(max(-inf, -24), 12)` is `-24`, so the clamp already floors it. An
    /// earlier version had a `guard gain > 0` here explaining that it stopped
    /// a NaN — a mutant that deleted the guard survived, which is how the
    /// explanation was found to be false. `label(forGain:)` does still guard,
    /// because it prints "−∞" rather than a number.
    public static func decibels(forGain gain: Double) -> Double {
        min(max(20 * log10(gain), minimumDecibels), maximumDecibels)
    }

    public static func gain(forDecibels decibels: Double) -> Double {
        let clamped = min(max(decibels, minimumDecibels), maximumDecibels)
        return pow(10, clamped / 20)
    }

    /// How many segments are lit for a gain.
    ///
    /// Unity lands on 8 of 12, not in the middle: the scale runs −24…+12, so
    /// two-thirds of it is attenuation. That asymmetry is deliberate and
    /// matches every hardware meter — you spend far more time pulling a level
    /// down than pushing it up.
    public static func litSegments(forGain gain: Double) -> Int {
        let span = maximumDecibels - minimumDecibels
        let position = (decibels(forGain: gain) - minimumDecibels) / span
        return Int((position * Double(segmentCount)).rounded())
    }

    /// Segments at or above unity, which a meter should show hot.
    ///
    /// Above 0 dB a track is being amplified, and amplification is where
    /// clipping comes from — the one thing a meter exists to warn about.
    public static var unitySegment: Int {
        litSegments(forGain: 1)
    }

    public static func isHot(segment index: Int) -> Bool { index >= unitySegment }

    /// A vertical drag, as a gain.
    ///
    /// `fraction` is 0 at the bottom of the ladder and 1 at the top, so a
    /// caller converts a point before calling. Quantised to the segments the
    /// user can actually see: a continuous value would let a drag land
    /// somewhere the meter cannot display, and the readout and the ladder
    /// would then disagree.
    public static func gain(forFraction fraction: Double) -> Double {
        let clamped = min(max(fraction, 0), 1)
        let segment = (clamped * Double(segmentCount)).rounded()
        let decibels = minimumDecibels
            + (segment / Double(segmentCount)) * (maximumDecibels - minimumDecibels)
        // No snap at unity. `pow(10, 0/20)` is EXACTLY 1.0 — an earlier
        // version snapped to it, claiming the result would otherwise land on
        // 0.9999 and leave a track fractionally quiet; a surviving mutant
        // showed that claim was wrong too. The reachability the snap was
        // protecting is a property of the arithmetic, and
        // `unityIsZeroDecibels` asserts it directly.
        return gain(forDecibels: decibels)
    }

    /// What the number beside the ladder says.
    public static func label(forGain gain: Double) -> String {
        guard gain > 0 else { return "−∞" }
        let value = decibels(forGain: gain)
        if abs(value) < 0.05 { return "0 dB" }
        return String(format: "%+.0f dB", value)
    }
}
