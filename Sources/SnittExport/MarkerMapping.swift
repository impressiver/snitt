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
///
/// The range-walk itself lives in `SnittDocument.TimeRangeMapping`, shared
/// with the preview's `MarkerJumpPoints` — this type only shapes the result
/// into `LoggedEvent`s.
public enum MarkerMapping {
    /// A marker whose raw timestamp falls inside a cut range is dropped, not
    /// clamped to the nearest kept boundary. Clamping would invent a chapter
    /// at a moment the viewer never sees, and several markers landing in the
    /// same cut would all collapse onto the same timestamp.
    public static func map(_ markers: [LoggedEvent], keptRanges: [TimeRange]) -> [LoggedEvent] {
        guard !keptRanges.isEmpty else { return [] }

        var mapped: [LoggedEvent] = []
        for marker in markers where marker.kind == .marker {
            guard let timeSeconds = TimeRangeMapping.trimmedTime(
                of: marker.timeSeconds, keptRanges: keptRanges) else {
                // A marker that matched no range fell inside a cut (or a
                // filtered sub-frame sliver) — dropped.
                continue
            }
            mapped.append(LoggedEvent(
                timeSeconds: timeSeconds,
                kind: .marker,
                label: marker.label))
        }
        return mapped.sorted { $0.timeSeconds < $1.timeSeconds }
    }
}
