// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import CoreGraphics
import Foundation
import SnittDocument

/// How much the picture changed, sampled over time.
///
/// A separate input rather than raw frames so the DETECTOR does not care how
/// the frames were obtained. The editor already decodes a filmstrip for the
/// timeline and can hand that straight over; a future higher-rate pass can be
/// swapped in without the detection logic knowing. D57 called that choice — a
/// dedicated decode versus reusing what exists — "a real architectural fork",
/// and this is the seam that keeps it from being one.
public struct FrameActivity: Sendable, Equatable {
    public let samplesPerSecond: Double
    /// Difference from the PREVIOUS sampled frame, 0...1. The first entry is
    /// the difference from nothing, so it is always 1 — a recording's opening
    /// frame is never "unchanged".
    public let differences: [Double]

    public init(samplesPerSecond: Double, differences: [Double]) {
        self.samplesPerSecond = samplesPerSecond
        self.differences = differences
    }

    /// Mean absolute luminance difference between successive frames, on a
    /// small downscale.
    ///
    /// Downscaled for the same reason `RecordingIcon.detailScore` is: this
    /// wants to know whether the PICTURE changed, not whether individual
    /// pixels did. Compression noise and sub-pixel text antialiasing move
    /// single pixels constantly on footage that is, to a viewer, perfectly
    /// still.
    public static func from(_ filmstrip: FilmstripFrames, side: Int = 32) -> FrameActivity {
        var previous: [Double]?
        var differences: [Double] = []
        for frame in filmstrip.frames {
            let luma = luminance(of: frame, side: side)
            if let previous, luma.count == previous.count, !luma.isEmpty {
                let total = zip(luma, previous).reduce(0.0) { $0 + abs($1.0 - $1.1) }
                differences.append(total / Double(luma.count))
            } else {
                differences.append(1.0)
            }
            previous = luma
        }
        return FrameActivity(samplesPerSecond: filmstrip.samplesPerSecond,
                             differences: differences)
    }

    private static func luminance(of image: CGImage, side: Int) -> [Double] {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return stride(from: 0, to: pixels.count, by: 4).map {
            (0.299 * Double(pixels[$0]) + 0.587 * Double(pixels[$0 + 1])
             + 0.114 * Double(pixels[$0 + 2])) / 255.0
        }
    }
}

/// Finds the spans of a recording where nothing happened (D57).
///
/// A span is dead air only when ALL of D57's criteria hold: the audio is
/// nothing but background noise, the picture is unchanged, no mouse or
/// keyboard event landed in it, no marker sits in it, and no spoken word is
/// still owed reading time.
///
/// **Absence of evidence is never evidence of death**, and that rule is what
/// keeps D44's original fear — "one long gap and delete the whole recording" —
/// from coming true. The criteria split into two kinds, and they are not
/// symmetrical:
///
/// - **Audio and picture are REQUIRED evidence.** Without waveform samples
///   there is no basis for saying the audio was quiet, and without frame
///   activity none for saying the picture was still. Missing either, this
///   returns nothing at all rather than everything.
/// - **Input, markers and speech are VETOES.** Their presence proves life;
///   their absence proves nothing. An empty event log means "input was not
///   logged" at least as often as it means "nobody touched anything" — D44 and
///   D49 make agent recordings log no OS input BY CONSTRUCTION, so for an
///   agent-driven demo the input criterion is satisfied for the whole
///   recording and the picture carries the entire decision. That is exactly
///   the case D57 warns about, and treating a missing log as proof of
///   stillness is how it would go wrong.
/// What is known about a recording's audio.
///
/// Three states, because an empty array of waveforms means two completely
/// different things and collapsing them cost this feature its most common case.
/// A 200-second screen recording with no voiceover has NO audio track at all;
/// treating that as "we could not measure the audio" made `auto-deep-trim`
/// silently do nothing on it — which is precisely the agent-recording case D57
/// says matters most, since those have no input events either.
public enum AudioEvidence: Sendable {
    /// The movie has no audio tracks. There is no sound, so "the audio is
    /// nothing but background noise" is trivially true.
    case silentByConstruction
    /// Measured peaks, one entry per audio track.
    case sampled([WaveformSamples])
    /// Audio may exist but has not been measured — still decoding, or the
    /// read failed. Nothing can be concluded, so nothing is.
    case unavailable
}

public enum AutoDeepTrim {

    /// Instants per second at which the criteria are evaluated.
    ///
    /// Finer than any input signal on purpose: the answer's resolution is
    /// bounded by the COARSEST evidence, and making the grid the coarsest
    /// thing as well would compound the two.
    static let resolution = 20.0

    public static func deadSpans(duration: Double,
                                 audio: AudioEvidence,
                                 frames: FrameActivity?,
                                 transcript: Transcript?,
                                 events: [LoggedEvent],
                                 criteria: DeepTrimCriteria) -> [TimeRange] {
        guard duration > 0 else { return [] }

        // Required evidence — but "there is no audio" is evidence, and "we did
        // not measure the audio" is not. See `AudioEvidence`.
        let tracks: [WaveformSamples]
        switch audio {
        case .unavailable:
            return []
        case .silentByConstruction:
            tracks = []
        case .sampled(let sampled):
            tracks = sampled.filter { !$0.peaks.isEmpty && $0.samplesPerSecond > 0 }
            // Sampling that produced nothing usable is `unavailable` in
            // disguise, not silence.
            guard !tracks.isEmpty else { return [] }
        }
        guard let frames, !frames.differences.isEmpty, frames.samplesPerSecond > 0
        else { return [] }

        let steps = max(1, Int((duration * resolution).rounded(.up)))
        var alive = [Bool](repeating: false, count: steps)

        // Thresholds per track, each against its OWN typical loud level: a
        // microphone and a system-audio tap sit at completely different levels,
        // and one threshold for both would call the quieter of them silent
        // throughout.
        let thresholds = tracks.map { track in
            SpeechChunker.silenceThreshold(for: track.peaks,
                                           fraction: criteria.audioSilenceFraction)
        }

        for step in 0..<steps {
            let t = Double(step) / resolution
            for (track, threshold) in zip(tracks, thresholds) {
                let index = Int(t * track.samplesPerSecond)
                // Past the end of a track's samples nothing is KNOWN, so
                // nothing is claimed: treated as alive, which leaves the tail
                // uncut rather than cutting it on no evidence.
                guard index < track.peaks.count else { alive[step] = true; break }
                if track.peaks[index] > threshold { alive[step] = true; break }
            }
            if alive[step] { continue }
            let frameIndex = Int(t * frames.samplesPerSecond)
            guard frameIndex < frames.differences.count else { alive[step] = true; continue }
            if frames.differences[frameIndex] > criteria.frameStillnessThreshold {
                alive[step] = true
            }
        }

        // The vetoes, painted over the grid.
        func markAlive(from: Double, to: Double) {
            let first = max(0, Int((from * resolution).rounded(.down)))
            let last = min(steps - 1, Int((to * resolution).rounded(.up)))
            guard first <= last else { return }
            for step in first...last { alive[step] = true }
        }
        for event in events {
            switch event.kind {
            case .click, .keystroke, .cursor, .marker:
                markAlive(from: event.timeSeconds - criteria.inputPadding,
                          to: event.timeSeconds + criteria.inputPadding)
            }
        }
        for word in transcript?.words ?? [] {
            markAlive(from: word.start,
                      to: word.start + word.duration + criteria.subtitleReadingTime)
        }

        // Maximal runs of not-alive, long enough to be worth removing.
        var spans: [TimeRange] = []
        var runStart: Int?
        for step in 0...steps {
            let isDead = step < steps && !alive[step]
            if isDead, runStart == nil { runStart = step }
            if !isDead, let start = runStart {
                let range = TimeRange(start: Double(start) / resolution,
                                      end: min(duration, Double(step) / resolution))
                if range.end - range.start >= criteria.minimumSpan { spans.append(range) }
                runStart = nil
            }
        }
        return spans
    }
}
