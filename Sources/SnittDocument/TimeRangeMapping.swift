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
}
