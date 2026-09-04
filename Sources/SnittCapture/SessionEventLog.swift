import Foundation
import SnittDocument

/// Everything timestamped that happens during a recording: markers a human or
/// agent deliberately drops (§4.12), and the fact that input occurred (§4.2).
///
/// An actor because entries arrive from the automation socket's connection
/// threads, from the main actor's hotkey, and from the event tap's own run-loop
/// thread, while the writer reads them at stop.
///
/// Renamed from `MarkerLog` when input events joined it — the old name would
/// have sent anyone looking for "where input events are stored" to the wrong
/// place.
public actor SessionEventLog {
    private var events: [LoggedEvent] = []

    public init() {}

    public func add(at timeSeconds: Double, kind: EventKind, label: String?) {
        // Input events are stripped of any label at the boundary rather than
        // trusting callers. A label is the only place key identity or click
        // content could reach the file, and events.json travels with the
        // bundle in plaintext — see this plan's ruling and §5.1.
        let safeLabel = (kind == .marker) ? label : nil
        events.append(LoggedEvent(timeSeconds: timeSeconds, kind: kind, label: safeLabel))
    }

    public func snapshot() -> [LoggedEvent] { events }

    public func counts() -> (markers: Int, inputEvents: Int) {
        let markers = events.filter { $0.kind == .marker }.count
        return (markers: markers, inputEvents: events.count - markers)
    }
}
