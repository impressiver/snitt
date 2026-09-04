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

@Test("Input event times are quantised to 100ms; marker times are not")
func inputTimesAreQuantisedButMarkersAreNot() async {
    // The tap is session-wide (.cgSessionEventTap) while the video is
    // window-scoped, so an event can describe typing in a window deliberately
    // kept out of frame — a master password typed mid-recording, say. At full
    // Double precision events.json then carries inter-keystroke intervals for
    // text the video does not contain. --auto-trim reasons about dead air in
    // seconds and loses nothing to 100ms.
    //
    // Markers keep full precision: their times are deliberate and a reviewer
    // jumps straight to them.
    let log = SessionEventLog()
    await log.add(at: 1.23456, kind: .keystroke, label: nil)
    await log.add(at: 2.06,    kind: .click,     label: nil)
    await log.add(at: 3.14159, kind: .marker,    label: "deliberate")

    let events = await log.snapshot()
    #expect(events[0].timeSeconds == 1.2)
    #expect(events[1].timeSeconds == 2.1)
    #expect(events[2].timeSeconds == 3.14159,
            "a marker's time is authored, not captured — it keeps its precision")
}

@Test("Quantisation yields short decimals, not floating-point noise")
func quantisationIsClean() {
    // events.json is read by humans; 0.30000000000000004 is not a timestamp.
    #expect(SessionEventLog.quantised(0.28) == 0.3)
    #expect(SessionEventLog.quantised(0.0) == 0.0)
    #expect(SessionEventLog.quantised(12.34) == 12.3)
}
