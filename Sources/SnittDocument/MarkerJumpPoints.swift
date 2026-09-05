import Foundation

/// A marker's position in the PREVIEW's timeline, which is the trimmed
/// timeline — not its position in the original recording.
public struct JumpPoint: Equatable, Sendable {
    public let timeSeconds: Double
    public let label: String

    public init(timeSeconds: Double, label: String) {
        self.timeSeconds = timeSeconds
        self.label = label
    }
}

/// Maps markers from recording time into preview time.
///
/// The preview plays the composition, whose timeline has the cuts removed, so
/// a marker at 8s in a recording with a 3s cut before it belongs at 5s here.
/// This must agree with `MarkerMapping` on the export side: a chapter list and
/// a scrub bar that disagree about the same recording are worse than either
/// alone. Both call `TimeRangeMapping.trimmedTime(of:keptRanges:)` for the
/// shared arithmetic and differ only in output shape.
public enum MarkerJumpPoints {
    public static func compute(events: [LoggedEvent],
                               keptRanges: [TimeRange]) -> [JumpPoint] {
        guard !keptRanges.isEmpty else { return [] }
        var points: [JumpPoint] = []
        for event in events where event.kind == .marker {
            guard let timeSeconds = TimeRangeMapping.trimmedTime(
                of: event.timeSeconds, keptRanges: keptRanges) else {
                // The marker sat inside a cut: dropped.
                continue
            }
            let label = (event.label?.isEmpty == false) ? event.label! : "Marker"
            points.append(JumpPoint(timeSeconds: timeSeconds, label: label))
        }
        return points.sorted { $0.timeSeconds < $1.timeSeconds }
    }
}
