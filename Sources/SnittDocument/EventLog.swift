import Foundation

public enum EventKind: String, Codable, Sendable {
    case click
    case keystroke
    case marker
}

/// One timestamped entry in the sidecar log. Times are seconds from the start
/// of the recording. Events are data, never drawn into the video (spec 4.5).
public struct LoggedEvent: Codable, Sendable {
    public var timeSeconds: Double
    public var kind: EventKind
    public var label: String?

    public init(timeSeconds: Double, kind: EventKind, label: String? = nil) {
        self.timeSeconds = timeSeconds
        self.kind = kind
        self.label = label
    }
}

public struct EventLog: Codable, Sendable {
    public var schemaVersion: Int
    public var events: [LoggedEvent]

    public init(schemaVersion: Int = 1, events: [LoggedEvent] = []) {
        self.schemaVersion = schemaVersion
        self.events = events
    }

    public func write(to bundle: SnittBundle) throws {
        try JSONCoding.encoder.encode(self).write(to: bundle.eventsURL)
    }

    public static func read(from bundle: SnittBundle) throws -> EventLog {
        try JSONCoding.decoder.decode(
            EventLog.self, from: Data(contentsOf: bundle.eventsURL)
        )
    }
}
