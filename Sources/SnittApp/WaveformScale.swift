// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// How a peak amplitude becomes a bar height, and when it counts as clipping.
///
/// Logarithmic, because linear amplitude is close to useless for finding speech
/// by eye. The first real recording made with this app peaked at 0.231 — a
/// perfectly healthy voiceover — which on a linear scale draws at 23% of the
/// band and reads as "almost nothing here". Hearing is roughly logarithmic, so
/// a dB scale puts the visual weight where the audible weight is: that same
/// peak lands near 79% against a -60 dB floor.
///
/// Pure, so the mapping is testable without a view, a recording, or a decoded
/// sample — the same split as `CropGeometry` and `TimelineFoldExtent`.
enum WaveformScale {
    /// Everything at or below this draws as silence.
    ///
    /// -60 dB is quiet enough to include room tone and breath — the things you
    /// look for when finding where a sentence starts — without letting the
    /// noise floor fill the band.
    static let floorDB = -60.0

    /// Linear amplitude at which a sample is treated as clipped.
    ///
    /// Just under 1.0 rather than above it: digital full scale IS 1.0, and a
    /// bucket that reached it has almost certainly been flattened, whether or
    /// not the stored float happens to exceed it.
    static let clippingThreshold = 0.99

    /// Bar height as a fraction of the half-band, 0...1.
    ///
    /// `gain` is applied first, so the waveform shows what will be EXPORTED
    /// rather than what was captured. Turning a track up until it clips should
    /// look like clipping before the export proves it.
    static func height(forPeak peak: Double, gain: Double = 1.0) -> Double {
        let amplified = max(0, peak) * max(0, gain)
        guard amplified > 0 else { return 0 }
        let decibels = 20 * log10(amplified)
        guard decibels > floorDB else { return 0 }
        return min(1, (decibels - floorDB) / -floorDB)
    }

    /// Whether this bucket clips once `gain` is applied.
    ///
    /// Two different things reach here and both matter: audio that was already
    /// clipped when captured, and audio the user has just turned up past full
    /// scale. The second is the one worth drawing, because it is still fixable.
    static func isClipped(peak: Double, gain: Double = 1.0) -> Bool {
        max(0, peak) * max(0, gain) >= clippingThreshold
    }
}
