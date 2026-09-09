// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// A marker's position in the PREVIEW's timeline, which is the trimmed
/// timeline — not its position in the original recording.
///
/// `id`/`transcript` (M5f Task 6): carried through from the source
/// `LoggedEvent` so a consumer that needs to address a SPECIFIC marker —
/// the timeline's marker track, dragging or editing one — has something to
/// name it by. Before this task nothing needed to: the sidebar jump list
/// only ever seeked to a point, never referred back to the marker that
/// produced it.
public struct JumpPoint: Equatable, Sendable {
    public let id: UUID
    public let timeSeconds: Double
    public let label: String
    public let transcript: String?
    /// True when the marker's source instant falls inside a cut, so
    /// `timeSeconds` is the FOLD it collapsed to rather than a moment the
    /// viewer sees. Always false for `MarkerJumpPoints.compute`, which drops
    /// those; set by `MarkerTrackPoints.compute`, which keeps them.
    public let isInsideCut: Bool

    public init(id: UUID = UUID(), timeSeconds: Double, label: String,
                transcript: String? = nil, isInsideCut: Bool = false) {
        self.id = id
        self.timeSeconds = timeSeconds
        self.label = label
        self.transcript = transcript
        self.isInsideCut = isInsideCut
    }
}

/// Marker positions for the timeline's marker TRACK, which — unlike the jump
/// list — keeps markers whose instant was cut.
///
/// `MarkerJumpPoints.compute` drops those, and is right to: a jump list exists
/// to seek somewhere, and clamping would offer to seek to a moment the viewer
/// never sees. The marker track is a different job. The timeline reused the
/// jump list to draw it, so a marker inside a cut vanished from the UI while
/// staying in `events.json` — invisible, unmovable, undeletable, and silently
/// back the moment the cut was removed.
///
/// Drawn at the fold the cut collapsed to, via the same
/// `TimeRangeMapping.nearestTrimmedTime` that already makes a click inside a
/// cut snap to the nearest kept edge, so the marker sits where the removed
/// span sits.
///
/// Accepted cost, and the reason the jump list does NOT do this: several
/// markers inside one cut collapse onto the same fold. Stacked markers at a
/// visible fold beat markers that cannot be seen at all — the user can drag
/// one out or delete it, neither of which was possible before.
public enum MarkerTrackPoints {
    public static func compute(events: [LoggedEvent],
                               keptRanges: [TimeRange]) -> [JumpPoint] {
        guard !keptRanges.isEmpty else { return [] }
        var points: [JumpPoint] = []
        for event in events where event.kind == .marker {
            let exact = TimeRangeMapping.trimmedTime(of: event.timeSeconds, keptRanges: keptRanges)
            let folded = exact ?? TimeRangeMapping.nearestTrimmedTime(
                toSourceTime: event.timeSeconds, keptRanges: keptRanges)
            guard let timeSeconds = folded else { continue }
            let label = (event.label?.isEmpty == false) ? event.label! : "Marker"
            points.append(JumpPoint(id: event.id, timeSeconds: timeSeconds,
                                    label: label, transcript: event.transcript,
                                    isInsideCut: exact == nil))
        }
        return points.sorted { $0.timeSeconds < $1.timeSeconds }
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
            points.append(JumpPoint(id: event.id, timeSeconds: timeSeconds,
                                    label: label, transcript: event.transcript))
        }
        return points.sorted { $0.timeSeconds < $1.timeSeconds }
    }
}
