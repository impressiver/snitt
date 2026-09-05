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

    /// The inverse of `trimmedTime(of:keptRanges:)`: maps an instant in the
    /// TRIMMED (output) timeline back to where it sits in the source
    /// recording.
    ///
    /// M4b whole-branch review, Critical finding #1: the editor's timeline
    /// view draws on the SOURCE clock (cuts only have a position there — by
    /// definition a cut is absent from the output), but the playhead and
    /// jump points the rest of the editor tracks are naturally in trimmed
    /// time — the player plays the composition, and `MarkerJumpPoints`
    /// already maps markers into it. Drawing them on the source axis without
    /// this inverse would place them at the wrong pixel the moment anything
    /// has been cut.
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
