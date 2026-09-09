// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittApp

/// The waveform's amplitude-to-height mapping.
///
/// The reason this is logarithmic is concrete: the first real recording made
/// with this app peaked at 0.231 — a healthy voiceover — which on a linear
/// scale draws at 23% of the band and reads as "almost nothing here".
@Suite
struct WaveformScaleTests {
    @Test("A quiet-but-audible peak occupies most of the band")
    func quietSpeechIsVisible() {
        // The case that motivated this. Linear would give 0.231.
        let height = WaveformScale.height(forPeak: 0.231)
        #expect(height > 0.7, "0.231 drew at \(height) — that is the linear scale")
        #expect(height < 1.0)
    }

    @Test("Full scale is the top of the band")
    func fullScaleIsFull() {
        #expect(abs(WaveformScale.height(forPeak: 1.0) - 1.0) < 0.001)
    }

    @Test("Silence is zero height, not the floor's height")
    func silenceIsZero() {
        // log10(0) is -infinity; a naive implementation produces NaN here and
        // draws a bar of undefined height, or crashes the rect maths.
        #expect(WaveformScale.height(forPeak: 0) == 0)
        #expect(WaveformScale.height(forPeak: 0.0001) == 0, "below the floor should be silent")
    }

    @Test("The scale is compressive: halving amplitude does not halve height")
    func scaleIsLogarithmic() {
        // The defining property. A linear implementation passes the full-scale
        // and silence tests above and fails this one.
        let loud = WaveformScale.height(forPeak: 0.8)
        let half = WaveformScale.height(forPeak: 0.4)
        #expect(half > loud / 2 + 0.1, "halving amplitude halved the height — this is linear")
    }

    @Test("Gain is applied before the scale, so the waveform shows the export")
    func gainAffectsHeight() {
        // Turning a track up must look louder before the export proves it.
        let unity = WaveformScale.height(forPeak: 0.1, gain: 1.0)
        let boosted = WaveformScale.height(forPeak: 0.1, gain: 4.0)
        #expect(boosted > unity)
    }

    @Test("Clipping is detected at full scale")
    func clippingAtFullScale() {
        #expect(WaveformScale.isClipped(peak: 1.0))
        #expect(!WaveformScale.isClipped(peak: 0.5))
    }

    @Test("Gain can INTRODUCE clipping, and that is the case worth drawing")
    func gainCanIntroduceClipping() {
        // Audio clipped at capture is already lost. Audio the user just pushed
        // past full scale is still fixable, which is the whole reason to show
        // it while they are dragging the slider.
        #expect(!WaveformScale.isClipped(peak: 0.6, gain: 1.0))
        #expect(WaveformScale.isClipped(peak: 0.6, gain: 2.0))
    }

    @Test("A zero or negative gain does not produce a negative height")
    func degenerateGain() {
        #expect(WaveformScale.height(forPeak: 0.5, gain: 0) == 0)
        #expect(WaveformScale.height(forPeak: 0.5, gain: -1) == 0)
    }
}
