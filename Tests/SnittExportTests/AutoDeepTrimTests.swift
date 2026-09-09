import CoreGraphics
import Foundation
import Testing
@testable import SnittDocument
@testable import SnittExport

/// Finding dead air (D57).
@Suite
struct AutoDeepTrimTests {

    private let duration = 20.0
    private let criteria = DeepTrimCriteria.preset(.default)

    /// A track that is silent everywhere except the given ranges.
    private func waveform(loud: [(Double, Double)], rate: Double = 10) -> WaveformSamples {
        let count = Int(duration * rate)
        var peaks = [Float](repeating: 0.001, count: count)
        for (from, to) in loud {
            for i in Int(from * rate)..<min(count, Int(to * rate)) { peaks[i] = 0.6 }
        }
        return WaveformSamples(track: "microphone", samplesPerSecond: rate, peaks: peaks)
    }

    /// A picture that is still everywhere except the given ranges.
    private func frames(moving: [(Double, Double)], rate: Double = 5) -> FrameActivity {
        let count = Int(duration * rate)
        var diffs = [Double](repeating: 0.0, count: count)
        diffs[0] = 1.0                                   // the opening frame always counts as change
        for (from, to) in moving {
            for i in Int(from * rate)..<min(count, Int(to * rate)) { diffs[i] = 0.4 }
        }
        return FrameActivity(samplesPerSecond: rate, differences: diffs)
    }

    private func spans(waveforms: [WaveformSamples]? = nil,
                       frames frameActivity: FrameActivity? = nil,
                       transcript: Transcript? = nil,
                       events: [LoggedEvent] = [],
                       criteria: DeepTrimCriteria? = nil) -> [TimeRange] {
        AutoDeepTrim.deadSpans(
            duration: duration,
            waveforms: waveforms ?? [waveform(loud: [(0, 2)])],
            frames: frameActivity ?? frames(moving: [(0, 2)]),
            transcript: transcript,
            events: events,
            criteria: criteria ?? self.criteria)
    }

    // MARK: - Finding it

    @Test("A silent, still, untouched span is dead air")
    func findsTheObviousDeadSpan() throws {
        // Activity for the first two seconds, then nothing for eighteen.
        let found = spans()
        let span = try #require(found.first)
        #expect(found.count == 1)
        #expect(abs(span.start - 2.0) < 0.3, "started at \(span.start)")
        #expect(abs(span.end - duration) < 0.3, "ended at \(span.end)")
    }

    @Test("Audio alone keeps a span alive")
    func audioKeepsItAlive() {
        // Someone narrating a still screen. The picture never changes and
        // nothing is clicked; deleting this would delete the narration.
        let found = spans(waveforms: [waveform(loud: [(0, 20)])],
                          frames: frames(moving: [(0, 0.4)]))
        #expect(found.isEmpty, "cut a span that had speech over it: \(found)")
    }

    @Test("A moving picture alone keeps a span alive")
    func pictureKeepsItAlive() {
        // The agent case, and D57 names it: agent recordings log no OS input by
        // construction, so the picture carries the entire decision. A silent
        // screencast of something happening must survive.
        let found = spans(waveforms: [waveform(loud: [(0, 0.4)])],
                          frames: frames(moving: [(0, 20)]))
        #expect(found.isEmpty, "cut a span where the screen was changing: \(found)")
    }

    @Test("A click keeps its own moment alive, with padding either side")
    func inputKeepsItAlive() {
        let found = spans(events: [LoggedEvent(timeSeconds: 10, kind: .click)])
        // The dead run is broken in two by the click rather than spanning it.
        #expect(found.count == 2, "got \(found.map { ($0.start, $0.end) })")
        #expect(found.allSatisfy { !($0.start...$0.end).contains(10.0) })
    }

    @Test("A marker keeps its own moment alive")
    func markerKeepsItAlive() {
        let found = spans(events: [LoggedEvent(timeSeconds: 10, kind: .marker, label: "Here")])
        #expect(found.count == 2, "a marker was trimmed away: \(found)")
    }

    @Test("A spoken word stays owed reading time after it finishes")
    func subtitlesAreOwedReadingTime() {
        // D44 missed this and D57 added it: a caption still on screen is not
        // dead air because nothing moved while it was being read. The word ENDS
        // at 10.3s; the span right after it must still be protected.
        let transcript = Transcript(schemaVersion: 1, words: [
            TranscriptWord(id: UUID(), text: "watch", start: 10.0, duration: 0.3, confidence: 1)
        ], locale: "en-US")
        let found = spans(transcript: transcript)
        let readingWindow = 10.3...(10.3 + criteria.subtitleReadingTime - 0.05)
        for span in found {
            for t in stride(from: readingWindow.lowerBound, to: readingWindow.upperBound, by: 0.1) {
                #expect(!(span.start...span.end).contains(t),
                        "trimmed \(t)s, while the word was still being read")
            }
        }
    }

    // MARK: - Refusing to guess

    @Test("With no audio samples, nothing is called dead")
    func noAudioEvidenceMeansNoSpans() {
        // The whole recording is silent and still as far as anything here
        // knows — and the answer is still NOTHING, because "we have no
        // waveform" is not "there was no sound".
        #expect(spans(waveforms: []).isEmpty)
        #expect(spans(waveforms: [WaveformSamples(track: "microphone",
                                                  samplesPerSecond: 10, peaks: [])]).isEmpty)
    }

    @Test("With no frame activity, nothing is called dead")
    func noVideoEvidenceMeansNoSpans() {
        // D44's original fear, stated directly: without frame-change detection
        // an agent recording — which logs no input by construction — looks like
        // one long gap, and a detector that trusted that would delete the whole
        // thing.
        // Called directly, NOT through `spans(frames:)`: that helper defaults a
        // nil argument back to real frame data, so the first version of this
        // test passed against a detector that ignored the nil entirely.
        func withFrames(_ frames: FrameActivity?) -> [TimeRange] {
            AutoDeepTrim.deadSpans(duration: duration,
                                   waveforms: [waveform(loud: [(0, 2)])],
                                   frames: frames, transcript: nil, events: [],
                                   criteria: criteria)
        }
        #expect(withFrames(nil).isEmpty)
        #expect(withFrames(FrameActivity(samplesPerSecond: 5, differences: [])).isEmpty)
    }

    @Test("A uniformly quiet track is silence, not loudness relative to itself")
    func quietTrackIsNotSelfNormalisedIntoSpeech() {
        // The threshold is a FRACTION of the track's own level, so without an
        // absolute floor a track sitting at 0.001 would clear its own bar
        // everywhere and nothing would ever be trimmable.
        let whisper = WaveformSamples(track: "microphone", samplesPerSecond: 10,
                                      peaks: [Float](repeating: 0.001, count: 200))
        #expect(!spans(waveforms: [whisper], frames: frames(moving: [(0, 2)])).isEmpty)
    }

    // MARK: - Shape of the answer

    @Test("A span shorter than the minimum is not worth cutting")
    func shortSpansAreIgnored() {
        // One second of quiet in the middle of activity, against a 1.5s minimum.
        let found = spans(waveforms: [waveform(loud: [(0, 9), (10, 20)])],
                          frames: frames(moving: [(0, 9), (10, 20)]))
        #expect(found.isEmpty, "cut a \(criteria.minimumSpan)s-minimum span anyway: \(found)")
    }

    @Test("Aggressive trims at least as much as conservative")
    func presetsOrderTheOutcome() {
        // Gaps of 0.6s, 1.2s, 2.0s and 4.2s, against minimums of 3.0 / 1.5 /
        // 0.8. The first version of this used one eighteen-second silence,
        // where every preset found the same span and the ordering held
        // vacuously — three identical presets would have passed it.
        let active = [(0.0, 1.0), (1.6, 2.6), (3.8, 4.8), (6.8, 7.8), (12.0, 20.0)]
        func removed(_ preset: DeepTrimPreset) -> Double {
            AutoDeepTrim.deadSpans(duration: duration,
                                   waveforms: [waveform(loud: active)],
                                   frames: frames(moving: active),
                                   transcript: nil, events: [],
                                   criteria: .preset(preset))
                .reduce(0) { $0 + ($1.end - $1.start) }
        }
        let (low, mid, high) = (removed(.conservative), removed(.default), removed(.aggressive))
        #expect(low <= mid, "conservative removed \(low), default \(mid)")
        #expect(mid <= high, "default removed \(mid), aggressive \(high)")
        // And the names have to MEAN something — three identical presets would
        // satisfy the ordering above.
        #expect(high > low, "every preset removed the same \(high)s")
    }

    @Test("Nothing is reported past the end of the recording")
    func spansStayInsideTheRecording() {
        for span in spans() {
            #expect(span.end <= duration + 0.001, "span ends at \(span.end), past \(duration)")
            #expect(span.start >= 0)
        }
    }
}

/// `FrameActivity.from` reduces decoded frames to "did the picture change".
@Suite
struct FrameActivityTests {
    private func solid(_ white: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: white, green: white, blue: white, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return ctx.makeImage()!
    }

    @Test("Identical frames register no change")
    func identicalFramesAreStill() {
        let frame = solid(0.5)
        let activity = FrameActivity.from(FilmstripFrames(samplesPerSecond: 5,
                                                          frames: [frame, frame, frame]))
        #expect(activity.differences.count == 3)
        #expect(activity.differences[1] < 0.001, "got \(activity.differences[1])")
        #expect(activity.differences[2] < 0.001)
    }

    @Test("A changed frame registers change proportional to how much it changed")
    func changedFramesRegister() {
        let activity = FrameActivity.from(FilmstripFrames(
            samplesPerSecond: 5, frames: [solid(0.0), solid(0.0), solid(1.0), solid(0.9)]))
        #expect(activity.differences[1] < 0.001)
        #expect(activity.differences[2] > 0.9, "black to white: \(activity.differences[2])")
        // A small change reads as a small number rather than saturating — the
        // threshold is a dial, and it can only be tuned if this is graded.
        #expect(activity.differences[3] > 0.05 && activity.differences[3] < 0.2,
                "white to near-white: \(activity.differences[3])")
    }

    @Test("The opening frame always counts as change")
    func firstFrameIsAlwaysChange() {
        // It has no predecessor to be identical to. Reporting 0 would make
        // every recording that opens on a still shot start with dead air.
        let activity = FrameActivity.from(FilmstripFrames(samplesPerSecond: 5,
                                                          frames: [solid(0.5)]))
        #expect(activity.differences == [1.0])
    }

    @Test("No frames means no differences, not a crash")
    func emptyFilmstrip() {
        #expect(FrameActivity.from(FilmstripFrames(samplesPerSecond: 5, frames: [])).differences.isEmpty)
    }
}
