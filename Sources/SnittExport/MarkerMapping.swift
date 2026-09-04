import Foundation
import SnittDocument

/// Maps marker timestamps from source-recording time into trimmed export
/// time.
///
/// `BuiltComposition.duration` is the TRIMMED duration, not the source's —
/// so a marker recorded at 8s in a bundle with a 5s head cut belongs at 3s
/// in the exported file. Writing raw bundle timestamps into the manifest or
/// the WebVTT chapters produces chapters that drift further out of sync the
/// more the user trims.
///
/// `keptRanges` must be the SAME set `CompositionBuilder` used to build the
/// composition — including its sub-frame-sliver filtering — or a marker can
/// map to a position that does not exist in the export.
public enum MarkerMapping {
    /// A marker whose raw timestamp falls inside a cut range is dropped, not
    /// clamped to the nearest kept boundary. Clamping would invent a chapter
    /// at a moment the viewer never sees, and several markers landing in the
    /// same cut would all collapse onto the same timestamp.
    public static func map(_ markers: [LoggedEvent], keptRanges: [TimeRange]) -> [LoggedEvent] {
        guard !keptRanges.isEmpty else { return [] }

        var mapped: [LoggedEvent] = []
        for marker in markers where marker.kind == .marker {
            var cursor = 0.0
            for (index, range) in keptRanges.enumerated() {
                let isLastRange = index == keptRanges.count - 1
                let withinRange = isLastRange
                    ? (marker.timeSeconds >= range.start && marker.timeSeconds <= range.end)
                    : (marker.timeSeconds >= range.start && marker.timeSeconds < range.end)
                if withinRange {
                    mapped.append(LoggedEvent(
                        timeSeconds: cursor + (marker.timeSeconds - range.start),
                        kind: .marker,
                        label: marker.label))
                    break
                }
                cursor += range.end - range.start
            }
            // A marker that matched no range fell inside a cut (or a
            // filtered sub-frame sliver) — dropped by falling through.
        }
        return mapped.sorted { $0.timeSeconds < $1.timeSeconds }
    }
}
