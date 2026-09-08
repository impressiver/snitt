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

    @Test("A pause in the middle splits the recording in two")
    func onePauseSplitsInTwo() throws {
        // The real case: 21s of speech with a ~1s pause at 10s.
        let samples = peaks(seconds: 21, silentRanges: [(10.0, 11.0)])
        let ranges = SpeechChunker.chunkRanges(peaks: samples, samplesPerSecond: rate, duration: 21)
        // `#require`, not a subscript: an implementation that never splits
        // returns ONE range, and `ranges[1]` would TRAP rather than fail —
        // `swift test` reports a crashed bundle with no summary line at all,
        // so the mutation that matters most would look like nothing ran.
        try #require(ranges.count == 2, "got \(ranges.count) chunk(s) — a single chunk IS the defect")
        // The boundary sits in the MIDDLE of the pause, so neither side loses a
        // word to a cut landing on its edge.
        #expect(abs(ranges[0].end - 10.5) < 0.2, "boundary at \(ranges[0].end)")
        #expect(ranges[1].end == 21)
    }

    @Test("Chunks tile the whole recording with no gap")
    func chunksTileTheRecording() {
        let samples = peaks(seconds: 30, silentRanges: [(8, 9), (17, 18)])
        let ranges = SpeechChunker.chunkRanges(peaks: samples, samplesPerSecond: rate, duration: 30)
        #expect(ranges.first?.start == 0)
        #expect(ranges.last?.end == 30)
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            #expect(abs(a.end - b.start) < 1e-9, "gap between \(a.end) and \(b.start)")
        }
    }

    @Test("A short pause does not split — it is within a sentence")
    func shortPausesDoNotSplit() {
        // 0.2s is a breath between words. Splitting there costs accuracy at the
        // boundary for nothing, and multiplies exports.
        let samples = peaks(seconds: 12, silentRanges: [(5.0, 5.2)])
        let ranges = SpeechChunker.chunkRanges(peaks: samples, samplesPerSecond: rate, duration: 12)
        #expect(ranges.count == 1)
    }

    @Test("Continuous speech is still bounded, split at its quietest point")
    func continuousSpeechIsBounded() throws {
        // No pause qualifies, so without a backstop this returns one chunk and
        // the original defect reappears inside it.
        var samples = peaks(seconds: 100, silentRanges: [])
        samples[Int(62 * rate)] = 0.05     // the quietest instant
        let ranges = SpeechChunker.chunkRanges(peaks: samples, samplesPerSecond: rate,
                                               duration: 100, maxChunkSeconds: 40)
        #expect(ranges.count >= 3, "100s of unbroken speech left as \(ranges.count) chunk(s)")
        #expect(ranges.allSatisfy { $0.end - $0.start <= 40.001 },
                "a chunk exceeded the limit: \(ranges.map { $0.end - $0.start })")
    }

    @Test("The silence threshold is relative to the recording's own level")
    func thresholdIsRelative() throws {
        // Speech at 0.015 — a genuinely quiet recording, well under any fixed
        // threshold tuned for a hot signal. Two pauses, so the failure is
        // legible rather than coincidental: with a fixed threshold the WHOLE
        // recording reads as silence, which collapses to one enormous silent
        // run and yields a single boundary at its midpoint. A first version of
        // this test used 0.05 speech, which clears a fixed 0.02 threshold
        // anyway, so it passed against the very implementation it forbade.
        let quiet = peaks(seconds: 30, silentRanges: [(8, 9), (17, 18)], level: 0.015)
        let ranges = SpeechChunker.chunkRanges(peaks: quiet, samplesPerSecond: rate, duration: 30)
        try #require(ranges.count == 3, "a quiet recording split into \(ranges.count) chunk(s)")
        #expect(abs(ranges[0].end - 8.5) < 0.2, "boundary at \(ranges[0].end), not the first pause")
        #expect(abs(ranges[1].end - 17.5) < 0.2, "boundary at \(ranges[1].end), not the second pause")
    }

    @Test("Silence at the very end adds no empty chunk")
    func trailingSilenceIsNotAChunk() {
        let samples = peaks(seconds: 12, silentRanges: [(10.0, 12.0)])
        let ranges = SpeechChunker.chunkRanges(peaks: samples, samplesPerSecond: rate, duration: 12)
        #expect(ranges.allSatisfy { $0.end - $0.start > 0.15 })
        #expect(ranges.last?.end == 12)
    }

    @Test("No peaks at all yields one chunk rather than nothing")
    func noPeaksIsOneChunk() {
        // A recording whose audio could not be sampled must still be attempted
        // whole, not silently skipped.
        let ranges = SpeechChunker.chunkRanges(peaks: [], samplesPerSecond: rate, duration: 9)
        #expect(ranges == [TimeRange(start: 0, end: 9)])
    }
}
