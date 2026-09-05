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
/// alone.
public enum MarkerJumpPoints {
    public static func compute(events: [LoggedEvent],
                               keptRanges: [TimeRange]) -> [JumpPoint] {
        guard !keptRanges.isEmpty else { return [] }
        var points: [JumpPoint] = []
        for event in events where event.kind == .marker {
            var cursor = 0.0
            for (index, range) in keptRanges.enumerated() {
                let isLast = index == keptRanges.count - 1
                let inside = isLast
                    ? (event.timeSeconds >= range.start && event.timeSeconds <= range.end)
                    : (event.timeSeconds >= range.start && event.timeSeconds < range.end)
                if inside {
                    let label = (event.label?.isEmpty == false)
                        ? event.label! : "Marker"
                    points.append(JumpPoint(
                        timeSeconds: cursor + (event.timeSeconds - range.start),
                        label: label))
                    break
                }
                cursor += range.end - range.start
            }
            // Falling through means the marker sat inside a cut: dropped.
        }
        return points.sorted { $0.timeSeconds < $1.timeSeconds }
    }
}
