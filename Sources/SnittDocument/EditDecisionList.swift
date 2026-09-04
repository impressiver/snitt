import Foundation

public enum AutoTrimError: Error, Equatable {
    /// The recording logged no input events, so there is nothing to trim
    /// against. Refusing is deliberate — see `autoTrimCuts`.
    case noInputEvents
}

public struct TimeRange: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

public struct TrackState: Codable, Sendable {
    public var track: String
    public var muted: Bool
    public var gain: Double

    public init(track: String, muted: Bool = false, gain: Double = 1.0) {
        self.track = track
        self.muted = muted
        self.gain = gain
    }
}

/// The only mutable part of a recording (spec section 7). Editing never
/// touches capture.mov.
public struct EditDecisionList: Codable, Sendable {
    public var schemaVersion: Int
    public var cuts: [TimeRange]
    public var trackStates: [TrackState]

    public init(schemaVersion: Int = 1,
                cuts: [TimeRange] = [],
                trackStates: [TrackState] = []) {
        self.schemaVersion = schemaVersion
        self.cuts = cuts
        self.trackStates = trackStates
    }

    /// The default EDL for a fresh recording: nothing cut, nothing muted.
    public static func fullRange() -> EditDecisionList {
        EditDecisionList(cuts: [], trackStates: [
            TrackState(track: "video"),
            TrackState(track: "microphone"),
            TrackState(track: "systemAudio"),
        ])
    }

    public func write(to bundle: SnittBundle) throws {
        try JSONCoding.encoder.encode(self).write(to: bundle.editURL)
    }

    public static func read(from bundle: SnittBundle) throws -> EditDecisionList {
        try JSONCoding.decoder.decode(
            EditDecisionList.self, from: Data(contentsOf: bundle.editURL)
        )
    }
}

extension EditDecisionList {
    /// Returns a copy that keeps only `range`, cutting the head and tail.
    ///
    /// Track states are carried over untouched: trimming edits time, not audio.
    public func trimmed(keeping range: TimeRange, duration: Double) -> EditDecisionList {
        var cuts: [TimeRange] = []
        if range.start > 0 { cuts.append(TimeRange(start: 0, end: range.start)) }
        if range.end < duration { cuts.append(TimeRange(start: range.end, end: duration)) }
        return EditDecisionList(schemaVersion: schemaVersion,
                                cuts: cuts,
                                trackStates: trackStates)
    }

    /// Cuts the dead air before the first and after the last logged INPUT event.
    ///
    /// Throws `noInputEvents` when the log contains none. That refusal is the
    /// point: §8 notes an agent driving an app through a CLI or HTTP produces
    /// no OS-level input at all, so its `events.json` holds only markers. An
    /// event-driven pass would see the whole recording as one gap and delete
    /// it — and an empty export looks like success.
    ///
    /// Markers are excluded deliberately. They are deliberate bookmarks, often
    /// dropped at the very start of a take, and counting them as activity
    /// would defeat head-trimming exactly when it is most useful.
    public static func autoTrimCuts(events: [LoggedEvent],
                                    duration: Double,
                                    padding: Double = 0.5) throws -> [TimeRange] {
        let inputTimes = events.filter { $0.kind != .marker }.map(\.timeSeconds).sorted()
        guard let first = inputTimes.first, let last = inputTimes.last else {
            throw AutoTrimError.noInputEvents
        }

        var cuts: [TimeRange] = []
        let head = max(0, first - padding)
        if head > 0 { cuts.append(TimeRange(start: 0, end: head)) }
        let tail = min(duration, last + padding)
        if tail < duration { cuts.append(TimeRange(start: tail, end: duration)) }
        return cuts
    }
}
