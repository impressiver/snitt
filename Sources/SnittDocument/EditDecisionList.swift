import Foundation

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
