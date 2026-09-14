// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Narration recorded in the editor, after the fact (D93).
///
/// **Why this is not simply "a start time and a file".** A voiceover is spoken
/// against OUTPUT time — you watch the edit and talk over it — while every
/// other track in a `.snitt` lives in SOURCE time. That makes it the first
/// thing in the document whose position has to be decided rather than read,
/// and the decision is: **narration is anchored to the FOOTAGE**. A later cut
/// takes the narration sitting over the removed picture with it, and
/// everything else stays aligned with the frames it describes.
///
/// The alternative — anchoring to the finished timeline — keeps the audio
/// continuous and lets the picture slide underneath it, so narration that
/// described one thing silently ends up over another. That failure has no
/// symptom until somebody watches the whole thing.
///
/// **Nothing is destroyed by a cut.** The recorded audio is one file in the
/// bundle and is never trimmed; `segments` describes where it plays. Undoing
/// the cut brings the narration back with the picture, which is §4.5's
/// non-destructive rule applying to narration for free.
public struct VoiceoverTrack: Codable, Equatable, Sendable {
    /// The audio, inside the bundle. A filename rather than a URL, because a
    /// bundle that is moved or copied must still resolve it.
    public var filename: String
    /// The whole recorded length, in seconds. Kept even when `segments` cover
    /// less of it, so "how much narration exists" and "how much currently
    /// plays" stay separable — the difference is exactly what a cut removed.
    public var durationSeconds: Double
    /// Where the narration plays, in SOURCE time, already resolved through the
    /// EDL that was in force when it was recorded.
    ///
    /// Resolved ONCE, at record time, rather than re-derived on every read.
    /// Re-deriving would need the EDL as it was then, which the document does
    /// not keep — and guessing it from the current one would move the
    /// narration every time an unrelated cut was made.
    public var segments: [VoiceoverSegment]

    public init(filename: String, durationSeconds: Double, segments: [VoiceoverSegment]) {
        self.filename = filename
        self.durationSeconds = durationSeconds
        self.segments = segments
    }
}

/// One continuous stretch of narration, and the source footage it sits over.
public struct VoiceoverSegment: Codable, Equatable, Sendable {
    /// Offset into the recorded audio file.
    public var voiceoverStart: Double
    /// The SOURCE instant that offset plays over.
    public var sourceStart: Double
    public var durationSeconds: Double

    public init(voiceoverStart: Double, sourceStart: Double, durationSeconds: Double) {
        self.voiceoverStart = voiceoverStart
        self.sourceStart = sourceStart
        self.durationSeconds = durationSeconds
    }

    public var voiceoverEnd: Double { voiceoverStart + durationSeconds }
    public var sourceEnd: Double { sourceStart + durationSeconds }
}

/// Turning "recorded from output second X for Y seconds" into source spans,
/// and back into the output spans an exporter places.
///
/// Pure, and separate from anything that records or plays audio, because the
/// arithmetic is the part with edge cases: narration that runs over a cut,
/// narration that outlives the recording, narration recorded against an edit
/// that has since changed.
public enum VoiceoverPlacement {

    /// The source spans narration covers, given where it started in the OUTPUT
    /// timeline and the ranges kept at that moment.
    ///
    /// Splits at every cut it crosses. A single span would have to pretend the
    /// removed footage was still there, which is the one thing the anchoring
    /// decision rules out: a cut the narration ran over is a place the
    /// narration must not describe.
    ///
    /// - Parameter outputStart: where recording began, in output seconds.
    /// - Parameter duration: how long the narration runs.
    /// - Parameter keptRanges: the EDL in force when it was recorded.
    public static func segments(outputStart: Double,
                                duration: Double,
                                keptRanges: [TimeRange]) -> [VoiceoverSegment] {
        guard duration > 0 else { return [] }
        var result: [VoiceoverSegment] = []
        // How far into the OUTPUT timeline each kept range begins. Walking
        // them in order is the same traversal the composition does, which is
        // why the two cannot disagree about where a second of narration lands.
        var outputCursor = 0.0
        var remaining = duration
        var consumed = 0.0

        for range in keptRanges {
            let length = range.end - range.start
            guard length > 0 else { continue }
            let rangeOutputEnd = outputCursor + length
            defer { outputCursor = rangeOutputEnd }
            // Entirely before the narration starts.
            guard rangeOutputEnd > outputStart else { continue }
            guard remaining > 0 else { break }

            // Where in THIS range the narration picks up: its own start the
            // first time, and the range's start every time after.
            let enterAtOutput = max(outputStart, outputCursor)
            let available = rangeOutputEnd - enterAtOutput
            let take = min(available, remaining)
            guard take > 0 else { continue }

            result.append(VoiceoverSegment(
                voiceoverStart: consumed,
                sourceStart: range.start + (enterAtOutput - outputCursor),
                durationSeconds: take))
            consumed += take
            remaining -= take
        }
        return result
    }

    /// Where a segment plays in the CURRENT output timeline, or nil when the
    /// footage under it has since been cut.
    ///
    /// Clipped rather than dropped when a cut removes only PART of it: half a
    /// sentence surviving is the honest result of cutting through narration,
    /// and dropping the whole segment would silently remove speech over
    /// footage that is still on screen.
    public static func outputSpans(of track: VoiceoverTrack,
                                   keptRanges: [TimeRange]) -> [VoiceoverOutputSpan] {
        var spans: [VoiceoverOutputSpan] = []
        var outputCursor = 0.0
        for range in keptRanges {
            let length = range.end - range.start
            guard length > 0 else { continue }
            let rangeOutputStart = outputCursor
            outputCursor += length

            for segment in track.segments {
                let overlapStart = max(segment.sourceStart, range.start)
                let overlapEnd = min(segment.sourceEnd, range.end)
                guard overlapEnd > overlapStart else { continue }
                spans.append(VoiceoverOutputSpan(
                    voiceoverStart: segment.voiceoverStart + (overlapStart - segment.sourceStart),
                    outputStart: rangeOutputStart + (overlapStart - range.start),
                    durationSeconds: overlapEnd - overlapStart))
            }
        }
        return spans.sorted { $0.outputStart < $1.outputStart }
    }
}

/// A slice of narration, and where it plays in the finished video.
public struct VoiceoverOutputSpan: Equatable, Sendable {
    public var voiceoverStart: Double
    public var outputStart: Double
    public var durationSeconds: Double

    public init(voiceoverStart: Double, outputStart: Double, durationSeconds: Double) {
        self.voiceoverStart = voiceoverStart
        self.outputStart = outputStart
        self.durationSeconds = durationSeconds
    }
}
