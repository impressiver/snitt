import Testing
import Foundation
@testable import SnittCapture
@testable import SnittDocument

/// Input an agent reports, that the OS never saw.
///
/// Browser automation dispatches into the page — `element.click()`, CDP's
/// `Input.dispatchMouseEvent` — so the real cursor never moves and nothing
/// reaches the event tap. The recording then shows a button changing state with
/// nothing visibly causing it. Reporting it is still RECORDING, not driving:
/// nothing is posted and no Accessibility grant is involved (D49 untouched).
@Suite
struct ReportedInputTests {
    private func log() -> SessionEventLog { SessionEventLog() }

    @Test("A reported event is marked reported, and carries its position")
    func reportedEventKeepsPositionAndProvenance() async {
        let events = log()
        await events.add(at: 1.0, kind: .click, label: nil, x: 0.5, y: 0.25, source: .reported)
        let event = await events.snapshot()[0]
        #expect(event.source == .reported)
        #expect(event.x == 0.5)
        #expect(event.y == 0.25)
    }

    @Test("An observed event stays observed and positionless")
    func observedEventIsUnchanged() async {
        // The tap supplies no coordinates today; this exists so adding the
        // fields cannot silently start claiming positions Snitt never saw.
        let events = log()
        await events.add(at: 1.0, kind: .click, label: nil)
        let event = await events.snapshot()[0]
        #expect(event.source == .observed)
        #expect(event.x == nil)
    }

    @Test("A reported click still loses its label")
    func reportedInputIsStrippedOfLabel() async {
        // The privacy boundary applies to reported input exactly as it does to
        // observed input. An agent describing WHAT it clicked would put click
        // content into a plaintext file that travels with the bundle, which is
        // what rule 1 exists to stop — and a well-meaning caller supplying it
        // is not a reason to trust it. Narration goes on a marker.
        let events = log()
        await events.add(at: 1.0, kind: .click, label: "Sign in as admin@example.com",
                   x: 0.5, y: 0.5, source: .reported)
        #expect(await events.snapshot()[0].label == nil)
    }

    @Test("A reported marker keeps its label and full precision")
    func markersAreUnaffected() async {
        let events = log()
        await events.add(at: 1.234_5, kind: .marker, label: "Clicked search", source: .reported)
        let event = await events.snapshot()[0]
        #expect(event.label == "Clicked search")
        #expect(event.timeSeconds == 1.234_5)
    }

    @Test("Reported input times are quantised like observed input")
    func reportedInputIsQuantised() async {
        let events = log()
        await events.add(at: 1.234_5, kind: .click, label: nil, x: 0, y: 0, source: .reported)
        #expect(await events.snapshot()[0].timeSeconds == SessionEventLog.quantised(1.234_5))
    }

    @Test("Position and provenance survive a write and read")
    func roundTripsThroughJSON() throws {
        let original = LoggedEvent(timeSeconds: 2.0, kind: .cursor,
                                   x: 0.1, y: 0.9, source: .reported)
        let data = try JSONEncoder().encode(EventLog(events: [original]))
        let decoded = try JSONDecoder().decode(EventLog.self, from: data)
        let event = decoded.events[0]
        #expect(event.kind == .cursor)
        #expect(event.x == 0.1)
        #expect(event.source == .reported)
    }

    @Test("An events.json written before provenance existed reads as observed")
    func legacyEventsAreObserved() throws {
        // Absent means observed, because every event written before this field
        // came from the tap — the historically true answer, not a neutral one.
        let json = #"{"schemaVersion":2,"events":[{"timeSeconds":1,"kind":"click"}]}"#
        let decoded = try JSONDecoder().decode(EventLog.self, from: Data(json.utf8))
        #expect(decoded.events[0].source == .observed)
        #expect(decoded.events[0].x == nil)
    }

    @Test("An ordinary recording's events.json gains no new keys")
    func observedEventsWriteNoSourceKey() throws {
        // `source` is written only when it is not the default, so a human
        // recording's file is byte-identical to what it was before this field.
        let data = try JSONEncoder().encode(
            EventLog(events: [LoggedEvent(timeSeconds: 1, kind: .click)]))
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(!text.contains("source"))
        #expect(!text.contains("\"x\""))
    }
}
