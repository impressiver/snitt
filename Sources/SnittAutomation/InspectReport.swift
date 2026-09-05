import Foundation
import SnittDocument

/// What `snitt inspect` returns (§8).
///
/// Exists because an agent cannot watch the video it just made. Every value
/// here is already computed elsewhere in the pipeline; this assembles them so
/// an agent can write something factually true in a pull request instead of
/// narrating a recording it has never seen.
public struct InspectReport: Codable, Sendable, Equatable {
    public struct Marker: Codable, Sendable, Equatable {
        public var timeSeconds: Double
        public var label: String?
    }

    public var bundlePath: String
    public var createdAt: Date
    public var initiator: String
    public var durationSeconds: Double?
    public var git: GitContext?
    public var health: CaptureHealth?
    /// Markers are listed; input events are only counted — the log records
    /// that input happened, never what, and listing it would be the same
    /// disclosure by another route.
    public var markers: [Marker]
    public var markerCount: Int
    public var inputEventCount: Int

    public static func report(for bundle: SnittBundle) throws -> InspectReport {
        let meta = try RecordingMetadata.read(from: bundle)
        // A partial bundle from an interrupted recording still deserves an
        // answer rather than an error the agent cannot act on.
        let events = (try? EventLog.read(from: bundle))?.events ?? []
        let markers = events.filter { $0.kind == .marker }

        return InspectReport(
            bundlePath: bundle.url.path,
            createdAt: meta.createdAt,
            initiator: meta.initiator.rawValue,
            durationSeconds: meta.durationSeconds,
            git: meta.git,
            health: meta.health,
            markers: markers.map { Marker(timeSeconds: $0.timeSeconds, label: $0.label) },
            markerCount: markers.count,
            inputEventCount: events.count - markers.count
        )
    }
}
