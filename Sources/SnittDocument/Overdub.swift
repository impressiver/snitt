// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// One take recorded over the microphone, after the fact (D102, amending D93).
///
/// **It replaces the captured microphone for its own span and nothing else.**
/// You watch the edit, start recording, say the line again, stop — and from
/// where you started to where you stopped, the microphone is what you just
/// said instead of what it heard. Everything either side is untouched.
///
/// D93 gave narration a THIRD audio track, and using the app showed that to be
/// the wrong model: a lane that only ever carries one kind of thing, a mute
/// and a gain nobody wants to set separately, and a mental model with three
/// audio sources in it when the recording has two. The teal third track is now
/// reserved for synthesised speech (D101), which genuinely is a separate voice
/// — one nobody ever spoke.
///
/// **`capture.mov` is still never touched** (§4.5). A take is its own file in
/// the bundle, and the microphone the exporter builds is assembled from both:
/// captured audio where no take covers it, take audio where one does. Deleting
/// a take brings the original microphone back, because the original was never
/// overwritten — which is the whole reason this is a composition-time decision
/// rather than a destructive one.
///
/// **Why this is not simply "a start time and a file".** A take is spoken
/// against OUTPUT time — you watch the edit and talk over it — while every
/// other track in a `.snitt` lives in SOURCE time. That makes its position
/// something to be decided rather than read, and the decision is unchanged
/// from D93: **a take is anchored to the FOOTAGE**. A later cut takes the
/// speech sitting over the removed picture with it, and everything else stays
/// aligned with the frames it describes.
///
/// The alternative — anchoring to the finished timeline — keeps the audio
/// continuous and lets the picture slide underneath it, so a line that
/// described one thing silently ends up over another. That failure has no
/// symptom until somebody watches the whole thing.
///
/// **Nothing is destroyed by a cut.** The recorded audio is never trimmed;
/// `segments` describes where it plays. Undoing the cut brings the take back
/// with the picture, which is §4.5's non-destructive rule applying for free.
public struct Overdub: Codable, Equatable, Sendable {
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
    public var segments: [OverdubSegment]

    public init(filename: String, durationSeconds: Double, segments: [OverdubSegment]) {
        self.filename = filename
        self.durationSeconds = durationSeconds
        self.segments = segments
    }
}

/// One continuous stretch of a take, and the source footage it sits over.
public struct OverdubSegment: Codable, Equatable, Sendable {
    /// Offset into the recorded audio file.
    public var takeStart: Double
    /// The SOURCE instant that offset plays over.
    public var sourceStart: Double
    public var durationSeconds: Double

    public init(takeStart: Double, sourceStart: Double, durationSeconds: Double) {
        self.takeStart = takeStart
        self.sourceStart = sourceStart
        self.durationSeconds = durationSeconds
    }

    public var takeEnd: Double { takeStart + durationSeconds }
    public var sourceEnd: Double { sourceStart + durationSeconds }
}

/// Turning "recorded from output second X for Y seconds" into source spans,
/// and back into the output spans an exporter places.
///
/// Pure, and separate from anything that records or plays audio, because the
/// arithmetic is the part with edge cases: narration that runs over a cut,
/// narration that outlives the recording, narration recorded against an edit
/// that has since changed.
public enum OverdubPlacement {

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
                                keptRanges: [TimeRange]) -> [OverdubSegment] {
        guard duration > 0 else { return [] }
        var result: [OverdubSegment] = []
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

            result.append(OverdubSegment(
                takeStart: consumed,
                sourceStart: range.start + (enterAtOutput - outputCursor),
                durationSeconds: take))
            consumed += take
            remaining -= take
        }
        return result
    }

    /// A moment in the recorded audio, as a SOURCE instant — or nil when that
    /// part of the narration sits over footage no longer in the document.
    ///
    /// The transcript needs this and nothing else does: a take is recognised
    /// against its own file, so every word comes back timed from the start of
    /// that FILE, while every other word in the transcript is timed against
    /// the capture. Left unmapped, a take's words would appear at the
    /// beginning of the recording and drift further from the picture the later
    /// it was spoken.
    public static func sourceTime(ofTakeTime time: Double,
                                  in track: Overdub) -> Double? {
        for segment in track.segments {
            // Half-open, so a word landing exactly on a boundary belongs to
            // the segment it starts rather than the one it ends.
            guard time >= segment.takeStart, time < segment.takeEnd else { continue }
            return segment.sourceStart + (time - segment.takeStart)
        }
        return nil
    }

    /// Whether any take has replaced the microphone at this SOURCE instant.
    ///
    /// The transcript's question. Words the capture's microphone was heard to
    /// say under a take are not in the finished audio at all — the take is
    /// what plays there — so leaving them in the transcript would show speech
    /// nobody can hear, beside the speech that replaced it, saying two
    /// different things about the same second.
    ///
    /// Half-open at the end, matching `sourceTime(ofTakeTime:)`: a word
    /// starting exactly where a take ends belongs to the capture again.
    public static func covers(sourceTime time: Double, overdubs: [Overdub]) -> Bool {
        overdubs.contains { overdub in
            overdub.segments.contains { time >= $0.sourceStart && time < $0.sourceEnd }
        }
    }

    /// Where a segment plays in the CURRENT output timeline, or nil when the
    /// footage under it has since been cut.
    ///
    /// Clipped rather than dropped when a cut removes only PART of it: half a
    /// sentence surviving is the honest result of cutting through narration,
    /// and dropping the whole segment would silently remove speech over
    /// footage that is still on screen.
    public static func outputSpans(of track: Overdub,
                                   keptRanges: [TimeRange]) -> [OverdubOutputSpan] {
        var spans: [OverdubOutputSpan] = []
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
                spans.append(OverdubOutputSpan(
                    takeStart: segment.takeStart + (overlapStart - segment.sourceStart),
                    outputStart: rangeOutputStart + (overlapStart - range.start),
                    durationSeconds: overlapEnd - overlapStart))
            }
        }
        return spans.sorted { $0.outputStart < $1.outputStart }
    }
}

/// A slice of a take, and where it plays in the finished video.
public struct OverdubOutputSpan: Equatable, Sendable {
    public var takeStart: Double
    public var outputStart: Double
    public var durationSeconds: Double

    public init(takeStart: Double, outputStart: Double, durationSeconds: Double) {
        self.takeStart = takeStart
        self.outputStart = outputStart
        self.durationSeconds = durationSeconds
    }
}

/// What the MICROPHONE track is made of, once takes have been recorded over it.
///
/// The piece D93 never needed. A third track was simply added alongside the
/// capture's own; an over-dub has to be woven INTO one of them, which means
/// someone has to decide, second by second, whether the microphone at that
/// moment is what was captured or what was said afterwards.
///
/// Pure, and here rather than in the exporter, because that decision is
/// arithmetic with edges — a take that runs over a cut, two takes that overlap,
/// a take recorded against an edit that has since changed — and the exporter
/// should only lay down what it is told to.
public enum MicrophoneTimeline {

    /// Where one stretch of microphone audio comes from.
    public enum Source: Equatable, Sendable {
        /// `capture.mov`'s own microphone track, by SOURCE time.
        case capture(start: Double)
        /// A take, by its index in the document's list and an offset into its
        /// own file.
        case overdub(index: Int, start: Double)
    }

    /// One stretch, and where it plays.
    public struct Piece: Equatable, Sendable {
        public var source: Source
        /// OUTPUT time — where the exporter places it.
        public var outputStart: Double
        public var durationSeconds: Double

        public init(source: Source, outputStart: Double, durationSeconds: Double) {
            self.source = source
            self.outputStart = outputStart
            self.durationSeconds = durationSeconds
        }

        public var outputEnd: Double { outputStart + durationSeconds }
    }

    /// The microphone track, in output order, with no gaps and no overlaps.
    ///
    /// Captured audio where no take covers it, take audio where one does. The
    /// result tiles the kept footage exactly: every second of output has
    /// exactly one microphone source, which is what makes deleting a take
    /// restore the original rather than leave a hole.
    ///
    /// **A later take wins.** Two takes over the same moment is somebody
    /// re-recording a line they had already re-recorded, and the second
    /// attempt is the one they meant — the same rule a recording head follows,
    /// and the only one where doing it again is a fix rather than a mess.
    public static func pieces(keptRanges: [TimeRange],
                              overdubs: [Overdub]) -> [Piece] {
        // Every take's spans in output time, later takes last so they can
        // overwrite what came before.
        var covering: [(span: OverdubOutputSpan, index: Int)] = []
        for (index, overdub) in overdubs.enumerated() {
            for span in OverdubPlacement.outputSpans(of: overdub, keptRanges: keptRanges) {
                covering.append((span, index))
            }
        }
        guard !covering.isEmpty else {
            return capturePieces(keptRanges: keptRanges)
        }

        // Resolved into a flat, non-overlapping cover by walking later takes
        // over earlier ones. Doing this BEFORE the capture is subtracted means
        // the capture only has to be subtracted once, against an answer that
        // is already settled.
        var cover: [(span: OverdubOutputSpan, index: Int)] = []
        for entry in covering {
            var kept: [(span: OverdubOutputSpan, index: Int)] = []
            for existing in cover {
                kept.append(contentsOf: subtract(existing, removing: entry.span))
            }
            cover = kept
            cover.append(entry)
        }
        cover.sort { $0.span.outputStart < $1.span.outputStart }

        var pieces: [Piece] = []
        for captured in capturePieces(keptRanges: keptRanges) {
            pieces.append(contentsOf: remainder(of: captured, under: cover))
        }
        pieces.append(contentsOf: cover.map {
            Piece(source: .overdub(index: $0.index, start: $0.span.takeStart),
                  outputStart: $0.span.outputStart,
                  durationSeconds: $0.span.durationSeconds)
        })
        return pieces.sorted { $0.outputStart < $1.outputStart }
    }

    /// The captured microphone, laid out in output time: one piece per kept
    /// range, which is exactly what the exporter builds when there are no
    /// takes at all.
    private static func capturePieces(keptRanges: [TimeRange]) -> [Piece] {
        var cursor = 0.0
        var pieces: [Piece] = []
        for range in keptRanges {
            let length = range.end - range.start
            guard length > 0 else { continue }
            pieces.append(Piece(source: .capture(start: range.start),
                                outputStart: cursor, durationSeconds: length))
            cursor += length
        }
        return pieces
    }

    /// `piece`, minus every stretch a take covers.
    private static func remainder(of piece: Piece,
                                  under cover: [(span: OverdubOutputSpan, index: Int)]) -> [Piece] {
        var out = [piece]
        for entry in cover {
            out = out.flatMap { subtract($0, removing: entry.span) }
        }
        return out
    }

    /// A capture piece with one span cut out of it — nothing, a head, a tail,
    /// or both.
    private static func subtract(_ piece: Piece, removing span: OverdubOutputSpan) -> [Piece] {
        let spanEnd = span.outputStart + span.durationSeconds
        guard spanEnd > piece.outputStart, span.outputStart < piece.outputEnd else { return [piece] }
        var out: [Piece] = []
        if span.outputStart > piece.outputStart {
            out.append(Piece(source: piece.source, outputStart: piece.outputStart,
                             durationSeconds: span.outputStart - piece.outputStart))
        }
        if spanEnd < piece.outputEnd {
            // The tail starts later in its own source too, by however much was
            // removed from the front. Advancing the output time and not the
            // source offset is how a cut ends up playing the wrong audio.
            let skipped = spanEnd - piece.outputStart
            let source: Source
            switch piece.source {
            case .capture(let start): source = .capture(start: start + skipped)
            case .overdub(let index, let start): source = .overdub(index: index, start: start + skipped)
            }
            out.append(Piece(source: source, outputStart: spanEnd,
                             durationSeconds: piece.outputEnd - spanEnd))
        }
        return out
    }

    /// A take span with another cut out of it, for resolving overlaps.
    private static func subtract(_ entry: (span: OverdubOutputSpan, index: Int),
                                 removing span: OverdubOutputSpan)
        -> [(span: OverdubOutputSpan, index: Int)] {
        let piece = Piece(source: .overdub(index: entry.index, start: entry.span.takeStart),
                          outputStart: entry.span.outputStart,
                          durationSeconds: entry.span.durationSeconds)
        return subtract(piece, removing: span).compactMap { remaining in
            guard case .overdub(let index, let start) = remaining.source else { return nil }
            return (OverdubOutputSpan(takeStart: start,
                                      outputStart: remaining.outputStart,
                                      durationSeconds: remaining.durationSeconds), index)
        }
    }
}
