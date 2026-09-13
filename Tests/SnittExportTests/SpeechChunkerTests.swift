// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittExport
@testable import SnittDocument

/// Splitting audio at utterance boundaries.
///
/// The defect this exists for: `SFSpeechRecognizer`'s single final result
/// carries only the LAST utterance, so a 21-second recording lost its first 11
/// seconds and a ten-minute demo would keep only its closing sentence. These
/// tests are written against that shape — the recording is split by ONE pause
/// in the middle — because a chunker that returns the whole file as one range
/// passes any test that only checks the ranges tile the duration.
@Suite
struct SpeechChunkerTests {
    private let rate = 10.0

    /// Peaks for `seconds` of audio, silent inside each given range.
    private func peaks(seconds: Double, silentRanges: [(Double, Double)],
                       level: Float = 0.2) -> [Float] {
        (0..<Int(seconds * rate)).map { index in
            let t = Double(index) / rate
            return silentRanges.contains { t >= $0.0 && t < $0.1 } ? 0.002 : level
        }
    }

}

/// One loud instant must not redefine what silence is.
///
/// The recording that produced these: narration recorded with SPEAKERS on
/// rather than headphones, so the music bled into the microphone and clipped at
/// 2.216. With the maximum as the reference the threshold landed at 0.177 —
/// above almost all of the speech, which peaked between 0.07 and 0.19. 81% of
/// the file read as silence and the transcript came back with five words for
/// thirty-two seconds. A cough, a door or a notification chime does the same.
@Suite
struct SilenceReferenceTests {
    private let rate = 10.0

    /// Quiet speech, one real pause, and one very loud instant.
    private func peaksWithSpike() -> [Float] {
        var samples = (0..<Int(20 * rate)).map { index -> Float in
            let t = Double(index) / rate
            return (t >= 10.0 && t < 11.0) ? 0.002 : 0.1     // speech is quiet
        }
        samples[Int(17 * rate)] = 2.216                      // the clip
        return samples
    }

    @Test("A spike does not turn the whole recording into silence")
    func spikeDoesNotSwallowSpeech() {
        let reference = SpeechChunker.referenceLevel(of: peaksWithSpike())
        // The maximum would be 2.216; the 90th percentile is the speech level.
        #expect(reference < 0.5, "reference \(reference) — a single instant set it")
        let threshold = max(SpeechChunker.absoluteSilenceFloor,
                            reference * SpeechChunker.silenceFraction)
        #expect(threshold < 0.05, "threshold \(threshold) is above the speech at 0.1")
    }

    @Test("The reference still tracks a recording with no spike at all")
    func referenceIsUnchangedWithoutSpikes() {
        // The fix must not make ordinary recordings behave differently.
        let flat = [Float](repeating: 0.4, count: 200)
        #expect(abs(SpeechChunker.referenceLevel(of: flat) - 0.4) < 0.001)
    }

    @Test("An empty recording has a reference of zero rather than crashing")
    func emptyPeaks() {
        #expect(SpeechChunker.referenceLevel(of: []) == 0)
    }
}
