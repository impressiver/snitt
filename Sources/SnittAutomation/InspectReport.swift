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
        let events = try Self.readEvents(for: bundle)
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

    /// Reads `bundle`'s event log, drawing the same absent-vs-unreadable
    /// distinction `MovieExporter.readBundleEvents` and
    /// `AutomationHost.readEventsForAutoTrim` already draw for `events.json`
    /// (§8) — a MISSING file is a partial bundle from an interrupted
    /// recording, which still deserves an answer rather than an error the
    /// agent cannot act on, but a file that EXISTS and fails to decode must
    /// be refused, not silently reported as "no markers".
    ///
    /// This was the one remaining `(try? EventLog.read(from: bundle))?.events
    /// ?? []` — the exact collapsing pattern a whole-branch review already
    /// fixed at `MovieExporter`'s and `AutomationHost`'s `events.json` call
    /// sites, and `DocumentOpener` fixed for `edit.json` — left standing on
    /// `snitt inspect`'s path. It is now doubly load-bearing (D60, M5f): a
    /// `schemaVersion` newer than this build understands throws from
    /// `EventLog.init(from:)`, and `try?` used to turn that refusal into a
    /// silently EMPTY marker list — an agent asking `snitt inspect` about a
    /// recording a newer Snitt build had already marked up would be told
    /// "no markers" instead of being told its own build is out of date.
    private static func readEvents(for bundle: SnittBundle) throws -> [LoggedEvent] {
        guard FileManager.default.fileExists(atPath: bundle.eventsURL.path) else {
            return []
        }
        return try EventLog.read(from: bundle).events
    }
}
