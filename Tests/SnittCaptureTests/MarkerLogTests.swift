import Testing
import Foundation
@testable import SnittCapture
import SnittDocument

@Test("Markers accumulate in the order they were added")
func markersAccumulateInOrder() async {
    let log = MarkerLog()
    await log.add(at: 1.0, label: "first")
    await log.add(at: 5.5, label: nil)
    let events = await log.snapshot()

    #expect(events.count == 2)
    #expect(events.map(\.timeSeconds) == [1.0, 5.5])
    #expect(events[0].label == "first")
    #expect(events[1].label == nil)
}

@Test("Every marker is stored as EventKind.marker")
func markersUseTheMarkerKind() async {
    // events.json is a shared log; M3b adds clicks and keystrokes to it. A
    // marker stored under any other kind would be invisible to chapter export.
    let log = MarkerLog()
    await log.add(at: 2.0, label: "x")
    #expect(await log.snapshot().allSatisfy { $0.kind == .marker })
}

@Test("A snapshot is a copy — later marks do not mutate it")
func snapshotIsACopy() async {
    let log = MarkerLog()
    await log.add(at: 1.0, label: "a")
    let first = await log.snapshot()
    await log.add(at: 2.0, label: "b")
    #expect(first.count == 1, "the snapshot handed to the writer must not change under it")
}
