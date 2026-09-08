import Foundation
import SnittDocument

/// Splits audio into pieces small enough that the recognizer treats each as ONE
/// utterance.
///
/// Exists because of a defect that made transcription useless on real
/// recordings: `SFSpeechRecognizer` segments file audio at silence, and its
/// single `isFinal` result carries only the LAST utterance. On a 21-second test
/// recording that lost the first 11 seconds; on a ten-minute demo it would lose
/// everything but the closing sentence. Partial results carry the running text
/// but report every timestamp as 0, so accumulating them is not an option when
/// word timings are the whole point (D62).
///
/// So the audio is cut at the same places the recognizer would have cut it, and
/// each piece is transcribed on its own with its offset added back.
///
/// Pure — the split decision is made from peaks alone, with no asset, no
/// recognizer and no I/O, which is what makes the boundary rules testable.
public enum SpeechChunker {
    /// Fraction of the recording's *typical loud* level below which audio
    /// counts as silence.
    ///
    /// Relative rather than absolute because recording levels vary by an order
    /// of magnitude between machines and microphones: the first real recording
    /// made with this app peaked at 0.231, so any fixed threshold tuned for a
    /// hot signal would treat all of it as silence.
    ///
    /// Measured against a HIGH PERCENTILE rather than the maximum, which is the
    /// difference between working and not. A single loud instant sets the floor
    /// for the whole recording if the maximum is the reference: a recording
    /// made with speakers on rather than headphones had music bleed into the
    /// microphone and clip at 2.216, which put the threshold at 0.177 — above
    /// almost all of the speech, so 81% of the file read as silence and the
    /// transcript came back with five words for thirty-two seconds. One cough,
    /// one door, one notification chime does the same thing.
    public static let silenceFraction: Float = 0.08
    /// A floor under that fraction, so a recording of pure noise does not have
    /// its own noise floor promoted to "speech".
    public static let absoluteSilenceFloor: Float = 0.004

    /// Pauses shorter than this are within-sentence and must not split.
    ///
    /// Splitting mid-sentence costs accuracy at the boundary; the recognizer
    /// ends an utterance on a pause of roughly this length, so matching it
    /// keeps our chunks and its utterances aligned.
    public static let defaultMinSilence = 0.45
    /// A backstop for continuous speech with no pause at all. Without it, an
    /// unbroken monologue would be one chunk and the original defect would
    /// reappear inside it.
    public static let defaultMaxChunk = 40.0

    /// The level the silence threshold is measured against: the 90th
    /// percentile of the peaks.
    ///
    /// High enough to sit among the loud passages rather than the quiet ones,
    /// and low enough that isolated spikes — a clip, a chime, music bleeding in
    /// from speakers — cannot drag it up and swallow the speech.
    static func referenceLevel(of peaks: [Float]) -> Float {
        guard !peaks.isEmpty else { return 0 }
        let sorted = peaks.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count) * 0.9))
        return sorted[index]
    }

    public static func chunkRanges(peaks: [Float],
                                   samplesPerSecond: Double,
                                   duration: Double,
                                   minSilenceSeconds: Double = defaultMinSilence,
                                   maxChunkSeconds: Double = defaultMaxChunk) -> [TimeRange] {
        guard duration > 0 else { return [] }
        guard !peaks.isEmpty, samplesPerSecond > 0 else {
            return [TimeRange(start: 0, end: duration)]
        }

        let threshold = max(absoluteSilenceFloor, referenceLevel(of: peaks) * silenceFraction)
        let minSilenceSamples = max(1, Int(minSilenceSeconds * samplesPerSecond))

        // Boundaries at the MIDDLE of each qualifying silence, so the pause is
        // shared between the chunks either side and neither loses a word to a
        // cut that lands on its edge.
        var boundaries: [Double] = []
        var runStart: Int?
        for index in peaks.indices {
            if peaks[index] < threshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                appendBoundary(&boundaries, start: start, end: index,
                               minSamples: minSilenceSamples, rate: samplesPerSecond)
                runStart = nil
            }
        }
        // A trailing silence needs no boundary: it ends the last chunk anyway.
        if let start = runStart {
            appendBoundary(&boundaries, start: start, end: peaks.count,
                           minSamples: minSilenceSamples, rate: samplesPerSecond)
        }

        var ranges = spans(between: boundaries, duration: duration)
        ranges = ranges.flatMap {
            split($0, ifLongerThan: maxChunkSeconds, peaks: peaks, rate: samplesPerSecond)
        }
        // A sliver between two adjacent pauses holds no speech and would cost
        // an export and a recognition to say so.
        return ranges.filter { $0.end - $0.start > 0.15 }
    }

    private static func appendBoundary(_ boundaries: inout [Double],
                                       start: Int, end: Int,
                                       minSamples: Int, rate: Double) {
        guard end - start >= minSamples else { return }
        let middle = Double(start + end) / 2 / rate
        // Never at 0 or past the end: a boundary there produces an empty chunk.
        if middle > 0.1 { boundaries.append(middle) }
    }

    private static func spans(between boundaries: [Double], duration: Double) -> [TimeRange] {
        var ranges: [TimeRange] = []
        var cursor = 0.0
        for boundary in boundaries where boundary > cursor && boundary < duration {
            ranges.append(TimeRange(start: cursor, end: boundary))
            cursor = boundary
        }
        if cursor < duration { ranges.append(TimeRange(start: cursor, end: duration)) }
        return ranges
    }

    /// Halves an over-long range at its QUIETEST interior point, recursively.
    ///
    /// The quietest point rather than the midpoint: with no pause long enough
    /// to qualify above, the least-bad place to cut is still wherever the
    /// speaker is closest to drawing breath.
    private static func split(_ range: TimeRange, ifLongerThan limit: Double,
                              peaks: [Float], rate: Double) -> [TimeRange] {
        guard range.end - range.start > limit else { return [range] }
        // Search the middle half only, so a split cannot shave a sliver off one
        // end and leave the rest still over the limit.
        let quarter = (range.end - range.start) / 4
        let lower = Int((range.start + quarter) * rate)
        let upper = min(peaks.count - 1, Int((range.end - quarter) * rate))
        guard upper > lower else {
            let middle = (range.start + range.end) / 2
            return [TimeRange(start: range.start, end: middle),
                    TimeRange(start: middle, end: range.end)]
        }
        var quietest = lower
        for index in lower...upper where peaks[index] < peaks[quietest] { quietest = index }
        let cut = Double(quietest) / rate
        return split(TimeRange(start: range.start, end: cut), ifLongerThan: limit,
                     peaks: peaks, rate: rate)
             + split(TimeRange(start: cut, end: range.end), ifLongerThan: limit,
                     peaks: peaks, rate: rate)
    }
}
