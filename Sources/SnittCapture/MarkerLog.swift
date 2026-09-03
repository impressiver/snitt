import Foundation
import SnittDocument

/// Timestamped bookmarks dropped while recording (§4.12).
///
/// An actor because marks arrive from the automation socket's connection
/// threads and from the main actor's hotkey, while the writer reads them at
/// stop. Ordering is arrival order, which is also time order in practice.
public actor MarkerLog {
    private var events: [LoggedEvent] = []

    public init() {}

    public func add(at timeSeconds: Double, label: String?) {
        events.append(LoggedEvent(timeSeconds: timeSeconds, kind: .marker, label: label))
    }

    public func snapshot() -> [LoggedEvent] { events }
}
