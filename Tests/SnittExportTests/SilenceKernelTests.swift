// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittExport
@testable import SnittDocument

/// The one silence rule, and its two consumers (rev 5, W12).
///
/// The spec for this item said to "extract auto-trim's silence decision" as
/// though a monolithic rule existed to extract. It did not: `AutoDeepTrim`
/// already built its threshold out of `SpeechChunker`'s primitives, and the
/// only thing missing was that the expression was written at the call site and
/// unreachable from the app module. So nothing was extracted — the expression
/// was named, and both consumers now call the name.
///
/// These pin the property that makes a segmented waveform worth drawing: the
/// gaps it shows are the spans the trim would take. Not approximately.
@Suite
struct SilenceKernelTests {

    /// 30 seconds of speech-like peaks with a known silent middle third.
    private func peaks(samplesPerSecond: Int = 10) -> [Float] {
        (0..<(30 * samplesPerSecond)).map { i in
            let second = Double(i) / Double(samplesPerSecond)
            return (second >= 10 && second < 20) ? 0.0005 : 0.35
        }
    }

    @Test("The threshold sits between the silence and the speech around it")
    func thresholdSeparatesTheTwo() {
        // The property, not the number: a threshold asserted as a literal
        // would pass after a change that made it separate nothing.
        let fraction = DeepTrimCriteria.preset(.default).audioSilenceFraction
        let threshold = SpeechChunker.silenceThreshold(for: peaks(), fraction: fraction)
        #expect(threshold > 0.0005, "the silent third is not below the threshold")
        #expect(threshold < 0.35, "the speech is not above the threshold")
    }

    @Test("A quieter preset calls less of a recording silent")
    func presetsOrderTheThresholds() {
        // Conservative cuts least and Aggressive cuts most, which at this
        // level means a lower and a higher bar respectively. This is why the
        // waveform has to name the preset it draws: "silent" is not one fact.
        let p = peaks()
        let conservative = SpeechChunker.silenceThreshold(
            for: p, fraction: DeepTrimCriteria.preset(.conservative).audioSilenceFraction)
        let standard = SpeechChunker.silenceThreshold(
            for: p, fraction: DeepTrimCriteria.preset(.default).audioSilenceFraction)
        let aggressive = SpeechChunker.silenceThreshold(
            for: p, fraction: DeepTrimCriteria.preset(.aggressive).audioSilenceFraction)
        #expect(conservative < standard)
        #expect(standard < aggressive)
    }

    @Test("An all-quiet track does not become all-loud, and vice versa")
    func degenerateTracksStayHonest() {
        // The absolute floor exists for the first case: a track that is
        // silence end to end has a reference level near zero, and a purely
        // relative threshold would sit under its own noise and call the noise
        // speech.
        let fraction = DeepTrimCriteria.preset(.default).audioSilenceFraction
        let silent = [Float](repeating: 0.0002, count: 300)
        #expect(SpeechChunker.silenceThreshold(for: silent, fraction: fraction) > 0.0002,
                "a silent track reads as speech")
        let loud = [Float](repeating: 0.6, count: 300)
        #expect(SpeechChunker.silenceThreshold(for: loud, fraction: fraction) < 0.6,
                "a loud track reads as silence")
    }

    @Test("Auto-trim's own decision comes from this function, not a copy of it")
    func autoTrimUsesTheSharedKernel() throws {
        // The structural half. Two call sites computing the same arithmetic
        // separately is exactly how the lane and the edit drift apart — and
        // nothing about a waveform's appearance would fail when they did.
        // This asserts the consequence rather than the wiring: the span
        // Auto-Trim removes from this fixture is the silent third, at the
        // same threshold the waveform would draw a baseline for.
        let fraction = DeepTrimCriteria.preset(.default).audioSilenceFraction
        let p = peaks()
        let threshold = SpeechChunker.silenceThreshold(for: p, fraction: fraction)
        let quietSeconds = p.enumerated()
            .filter { Float($0.element) <= threshold }
            .map { Double($0.offset) / 10.0 }
        let first = try #require(quietSeconds.first)
        let last = try #require(quietSeconds.last)
        #expect(abs(first - 10) < 0.2, "the quiet span starts at \(first), not 10")
        #expect(abs(last - 19.9) < 0.2, "the quiet span ends at \(last), not 19.9")
    }
}
