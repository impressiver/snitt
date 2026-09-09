// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Shared range-walk behind both marker mappers (`MarkerJumpPoints` here and
/// `MarkerMapping` in `SnittExport`).
///
/// The preview and the export must never disagree about where a moment in
/// the original recording lands in the trimmed timeline — a chapter list and
/// a scrub bar describing the same recording differently is worse than
/// either alone. This is the one place that arithmetic lives.
public enum TimeRangeMapping {
    /// Maps a recording-time instant into the trimmed timeline, or `nil` if
    /// it falls inside a cut (a gap between `keptRanges`, including any
    /// sub-frame slivers the caller has already filtered out of
    /// `keptRanges`).
    ///
    /// Boundary rule: every kept range except the last is half-open
    /// (`>= start && < end`); the last kept range is closed at both ends
    /// (`>= start && <= end`). That means an instant sitting exactly on the
    /// end of a non-final kept range (equivalently, the start of the cut
    /// that follows it) belongs to neither range and maps to `nil`, while an
    /// instant exactly at the recording's own final moment still maps. An
    /// instant landing on the start of the NEXT kept range maps to that
    /// range's beginning — it was never cut.
    public static func trimmedTime(of recordingTime: Double,
                                   keptRanges: [TimeRange]) -> Double? {
        guard !keptRanges.isEmpty else { return nil }

        var cursor = 0.0
        for (index, range) in keptRanges.enumerated() {
            let isLastRange = index == keptRanges.count - 1
            let withinRange = isLastRange
                ? (recordingTime >= range.start && recordingTime <= range.end)
                : (recordingTime >= range.start && recordingTime < range.end)
            if withinRange {
                return cursor + (recordingTime - range.start)
            }
            cursor += range.end - range.start
        }
        // Matched no range: fell inside a cut. Dropped, not clamped —
        // clamping would invent a moment the viewer never sees, and several
        // instants landing in the same cut would collapse onto one instant.
        return nil
    }

    /// The trimmed-time position for a source instant, snapping to the
    /// nearest kept boundary when the instant falls inside a cut.
    ///
    /// `trimmedTime(of:keptRanges:)` returns nil there, which is honest —
    /// a cut instant has no frame. But answering with nothing at all is the
    /// silent no-op this project keeps finding, and every instant inside a
    /// cut has a well-defined place on the output timeline regardless: the
    /// single point immediately after everything kept before it and
    /// immediately before everything kept after it. That is the moment a
    /// person can actually see, and it is what every editor does.
    ///
    /// Handling the gap IS this function's purpose — the property that makes
    /// it usable for `Timebase.foldPosition(for:)`, which asks exactly this
    /// question of a cut's own start. Do not confuse it with
    /// `sourceTime(ofTrimmedTime:keptRanges:)` below, which converts the
    /// other direction and genuinely cannot land in a gap: this doc block
    /// used to be that function's, misattached here, complete with a "can
    /// never fall in a 'gap'" claim that is false of this function and was
    /// contradicted by its own next paragraph. It was also the only place in
    /// `Sources/` citing M4b Critical #1, and said the editor's timeline
    /// "draws on the SOURCE clock" — true when written, false since M5f Task
    /// 3 moved the view onto the output axis. Two implementers read it while
    /// deciding which axis to interpret gestures on, and the M5f
    /// whole-branch review found they had reproduced the very defect the
    /// citation names (Criticals C1/C2). A stale comment on load-bearing
    /// code is not a tidiness problem.
    ///
    /// ORDER DEPENDENCE, the other half of `Timebase.foldPosition`'s warning
    /// (M5f whole-branch review, F7): this walks `keptRanges` accumulating
    /// `cursor` in ARRAY order and assumes that order is also ASCENDING TIME
    /// order — true for everything `KeptRanges.compute` produces today. The
    /// refinement pass for slice/reorder (Tier 2) named this function as
    /// the one that genuinely breaks under a reordered timeline: with
    /// out-of-order ranges every answer past the first misordered one is
    /// wrong, silently, and both consumers (`onScrub`'s snap and every
    /// fold's drawn position) would be wrong together. Whoever lands
    /// reorder must revisit this function, not just its callers.
    public static func nearestTrimmedTime(toSourceTime sourceTime: Double,
                                          keptRanges: [TimeRange]) -> Double? {
        guard !keptRanges.isEmpty else { return nil }
        var cursor = 0.0
        for range in keptRanges {
            // Before this range means inside the cut that precedes it (or
            // before the recording). The answer is the cut's own position in
            // trimmed time, which is everything kept so far.
            if sourceTime < range.start { return cursor }
            if sourceTime <= range.end { return cursor + (sourceTime - range.start) }
            cursor += range.end - range.start
        }
        // Past the last kept range: the end of the output.
        return cursor
    }

    /// The inverse of `trimmedTime(of:keptRanges:)`: maps an instant in the
    /// TRIMMED (output) timeline back to where it sits in the source
    /// recording.
    ///
    /// M4b whole-branch review, Critical finding #1: the editor tracks its
    /// playhead and jump points in trimmed time — the player plays the
    /// composition, and `MarkerJumpPoints` already maps markers into it —
    /// while cuts, selections and everything written to `edit.json` are
    /// source time. Anything crossing between the two clocks needs this
    /// conversion, and doing it at the wrong moment (or not at all) puts
    /// the value at the wrong instant the moment anything has been cut.
    /// `Timebase.sourceTime(forOutput:)` is the typed entry point the
    /// editor actually calls; this is its implementation.
    ///
    /// Unlike the forward direction, this can never fall in a "gap" — the
    /// trimmed timeline has no cuts in it by construction, `keptRanges` tile
    /// it edge to edge — so every `trimmedTime` in `0...totalDuration` maps
    /// to exactly one source instant. `nil` here only means `trimmedTime`
    /// itself was out of range (negative, past the end, or `keptRanges` is
    /// empty).
    ///
    /// Boundary rule mirrors `trimmedTime(of:keptRanges:)`: every kept range
    /// except the last claims its trimmed span half-open, the last one
    /// closed at both ends — so the two functions round-trip.
    public static func sourceTime(ofTrimmedTime trimmedTime: Double,
                                  keptRanges: [TimeRange]) -> Double? {
        guard !keptRanges.isEmpty else { return nil }

        var cursor = 0.0
        for (index, range) in keptRanges.enumerated() {
            let length = range.end - range.start
            let isLastRange = index == keptRanges.count - 1
            let withinRange = isLastRange
                ? (trimmedTime >= cursor && trimmedTime <= cursor + length)
                : (trimmedTime >= cursor && trimmedTime < cursor + length)
            if withinRange {
                return range.start + (trimmedTime - cursor)
            }
            cursor += length
        }
        // trimmedTime was negative, or past the trimmed timeline's own end.
        return nil
    }
}
