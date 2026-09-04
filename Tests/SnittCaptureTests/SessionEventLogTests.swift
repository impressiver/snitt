import Testing
import Foundation
@testable import SnittCapture
import SnittDocument

@Test("Markers and input events accumulate in one log, in arrival order")
func markersAndEventsShareOneLog() async {
    let log = SessionEventLog()
    await log.add(at: 1.0, kind: .marker, label: "start")
    await log.add(at: 2.0, kind: .keystroke, label: nil)
    await log.add(at: 3.0, kind: .click, label: nil)

    let events = await log.snapshot()
    #expect(events.map(\.kind) == [.marker, .keystroke, .click])
    #expect(events.map(\.timeSeconds) == [1.0, 2.0, 3.0])
}

@Test("Input events never carry a label")
func inputEventsCarryNoLabel() async {
    // The ruling: log the FACT of input, never its content. A label on a
    // keystroke is where a key name would end up, and events.json travels
    // with the bundle in plaintext (§5.1's password-notification argument).
    let log = SessionEventLog()
    await log.add(at: 1.0, kind: .keystroke, label: "should be dropped")
    await log.add(at: 2.0, kind: .click, label: "also dropped")

    let events = await log.snapshot()
    #expect(events.allSatisfy { $0.label == nil },
            "an input event must never carry content, even if a caller passes some")
}

@Test("Markers keep their labels")
func markersKeepLabels() async {
    // A marker's label is authored by a human or an agent describing its own
    // action — deliberate, not captured. It stays.
    let log = SessionEventLog()
    await log.add(at: 1.0, kind: .marker, label: "ran the tests")
    #expect(await log.snapshot().first?.label == "ran the tests")
}

@Test("Counts separate markers from input events")
func countsSeparateKinds() async {
    let log = SessionEventLog()
    await log.add(at: 1.0, kind: .marker, label: "a")
    await log.add(at: 2.0, kind: .keystroke, label: nil)
    await log.add(at: 3.0, kind: .click, label: nil)

    let counts = await log.counts()
    #expect(counts.markers == 1)
    #expect(counts.inputEvents == 2)
}

@Test("A snapshot is a copy — later additions do not mutate it")
func snapshotIsACopy() async {
    let log = SessionEventLog()
    await log.add(at: 1.0, kind: .marker, label: "a")
    let first = await log.snapshot()
    await log.add(at: 2.0, kind: .click, label: nil)
    #expect(first.count == 1)
}
