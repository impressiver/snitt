import Foundation

/// Turns an EDL's cuts into the ranges that survive into the export.
///
/// `cuts` are the ranges REMOVED — `EditDecisionList.fullRange()` returns
/// `cuts: []` for a recording with nothing trimmed — so what gets exported is
/// their complement.
///
/// Pure, and separated for that reason: this is where the off-by-one and
/// empty-input mistakes live, and none of them need AVFoundation to find.
public enum KeptRanges {
    public static func compute(duration: Double, cuts: [TimeRange]) -> [TimeRange] {
        // Normalise first. Callers are not required to sort, and trimming twice
        // legitimately produces overlaps; subtracting each cut in turn would
        // yield a range whose end precedes its start, which AVFoundation
        // accepts and then renders as garbage.
        let normalised = cuts
            .map { TimeRange(start: max(0, min($0.start, duration)),
                             end: max(0, min($0.end, duration))) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }

        var merged: [TimeRange] = []
        for cut in normalised {
            if let last = merged.last, cut.start <= last.end {
                merged[merged.count - 1] = TimeRange(start: last.start,
                                                     end: max(last.end, cut.end))
            } else {
                merged.append(cut)
            }
        }

        var kept: [TimeRange] = []
        var cursor = 0.0
        for cut in merged {
            if cut.start > cursor { kept.append(TimeRange(start: cursor, end: cut.start)) }
            cursor = max(cursor, cut.end)
        }
        if cursor < duration { kept.append(TimeRange(start: cursor, end: duration)) }
        return kept
    }
}
