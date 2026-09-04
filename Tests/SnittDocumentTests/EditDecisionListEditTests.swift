import Testing
import Foundation
@testable import SnittDocument

private func input(_ t: Double) -> LoggedEvent {
    LoggedEvent(timeSeconds: t, kind: .keystroke, label: nil)
}
private func marker(_ t: Double) -> LoggedEvent {
    LoggedEvent(timeSeconds: t, kind: .marker, label: "m")
}

@Test("Trimming to a range cuts the head and the tail")
func trimKeepsTheNamedRange() {
    let edl = EditDecisionList.fullRange()
        .trimmed(keeping: TimeRange(start: 5, end: 25), duration: 30)
    #expect(edl.cuts == [TimeRange(start: 0, end: 5), TimeRange(start: 25, end: 30)])
}

@Test("Trimming preserves track states — it edits time, not audio")
func trimPreservesTrackStates() {
    let edl = EditDecisionList.fullRange()
        .trimmed(keeping: TimeRange(start: 1, end: 2), duration: 10)
    #expect(edl.trackStates.count == 3)
}

@Test("Trimming to the full range produces no cuts")
func trimToFullRangeIsInert() {
    let edl = EditDecisionList.fullRange()
        .trimmed(keeping: TimeRange(start: 0, end: 10), duration: 10)
    #expect(edl.cuts.isEmpty)
}

@Test("Auto-trim clips before the first and after the last input event")
func autoTrimClipsTheBookends() throws {
    let cuts = try EditDecisionList.autoTrimCuts(
        events: [input(5), input(10), input(20)], duration: 30, padding: 0.5)
    #expect(cuts == [TimeRange(start: 0, end: 4.5), TimeRange(start: 20.5, end: 30)])
}

@Test("Auto-trim REFUSES an event log with no input events")
func autoTrimRefusesEmptyLog() {
    // §8: an agent driving an app through a CLI produces no OS-level input, so
    // its events.json holds only markers. Trimming on that basis would delete
    // the entire recording — and would look like it worked.
    #expect(throws: AutoTrimError.noInputEvents) {
        _ = try EditDecisionList.autoTrimCuts(events: [], duration: 30)
    }
    #expect(throws: AutoTrimError.noInputEvents) {
        _ = try EditDecisionList.autoTrimCuts(events: [marker(1), marker(9)], duration: 30)
    }
}

@Test("Markers do not count as activity for auto-trim")
func markersAreNotActivity() throws {
    // A marker at 0.2s ("start of demo") would otherwise defeat head-trimming
    // at exactly the moment it is most wanted.
    let cuts = try EditDecisionList.autoTrimCuts(
        events: [marker(0.2), input(10), input(12)], duration: 20, padding: 0.5)
    #expect(cuts.first == TimeRange(start: 0, end: 9.5))
}

@Test("Padding never pushes a cut past the recording, or below zero")
func paddingIsClamped() throws {
    let cuts = try EditDecisionList.autoTrimCuts(
        events: [input(0.1), input(29.9)], duration: 30, padding: 0.5)
    #expect(cuts.allSatisfy { $0.start >= 0 && $0.end <= 30 })
    #expect(cuts.allSatisfy { $0.end >= $0.start })
}

@Test("Activity spanning the whole recording produces no cuts")
func nothingToTrim() throws {
    let cuts = try EditDecisionList.autoTrimCuts(
        events: [input(0), input(30)], duration: 30, padding: 0.5)
    #expect(cuts.isEmpty)
}
