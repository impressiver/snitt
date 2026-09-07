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

@Test("An interior cut a person made in the editor survives a trim that keeps a range containing it")
func trimPreservesAnInteriorCutInsideTheKeptRange() {
    // D60: `trimmed(keeping:)` used to build `cuts` from scratch and return
    // it, discarding `self.cuts` outright — make an interior cut in the
    // editor, run `snitt trim`, and it is gone, permanently, since
    // `capture.mov` is never rewritten. THIS is the property that matters:
    // not "trim produced two bookend cuts" (true even of the broken code on
    // a fresh recording with nothing interior to lose) but "a cut someone
    // already made is still there afterward."
    let edl = EditDecisionList(cuts: [TimeRange(start: 10, end: 12)])
        .trimmed(keeping: TimeRange(start: 5, end: 25), duration: 30)
    #expect(edl.cuts.contains(TimeRange(start: 10, end: 12)),
            "an interior cut fully inside the kept range must not be discarded by a trim")
    #expect(edl.cuts.count == 3,
            "expected the two new bookends plus the untouched interior cut, got \(edl.cuts)")
}

@Test("An existing cut straddling the new head boundary is clipped, merging into the head bookend")
func trimClipsACutStraddlingTheHeadBoundary() {
    // Decision (documented again at the implementation): a straddling cut is
    // effectively CLIPPED to the part still inside the kept range, not
    // dropped (that would silently un-cut the sliver of it that's still
    // inside [range.start, range.end]) and not kept whole as a second,
    // unclipped entry (that would misrepresent seconds already covered by
    // the new head bookend as a distinct edit). The old cut [3,8) straddles
    // the new head boundary at 5; only [5,8) of it is still inside the kept
    // range, and that sliver is contiguous with the head bookend [0,5), so
    // the two coalesce into one [0,8) entry.
    let edl = EditDecisionList(cuts: [TimeRange(start: 3, end: 8)])
        .trimmed(keeping: TimeRange(start: 5, end: 25), duration: 30)
    #expect(edl.cuts == [TimeRange(start: 0, end: 8), TimeRange(start: 25, end: 30)],
            "got \(edl.cuts)")
}

@Test("An existing cut straddling the new tail boundary is clipped, merging into the tail bookend")
func trimClipsACutStraddlingTheTailBoundary() {
    // Mirror of the head-boundary case: [22,27) straddles the new tail
    // boundary at 25; the [22,25) sliver still inside the kept range
    // coalesces with the tail bookend [25,30) into [22,30).
    let edl = EditDecisionList(cuts: [TimeRange(start: 22, end: 27)])
        .trimmed(keeping: TimeRange(start: 5, end: 25), duration: 30)
    #expect(edl.cuts == [TimeRange(start: 0, end: 5), TimeRange(start: 22, end: 30)],
            "got \(edl.cuts)")
}

@Test("An existing cut entirely outside the kept range is dropped as redundant, not kept as a duplicate")
func trimDropsACutEntirelyOutsideTheKeptRange() {
    // Decision: dropped. A cut entirely outside [range.start, range.end] is,
    // by construction, wholly a subset of the new head or tail bookend's
    // span — so it carries no information the bookend doesn't already
    // carry. Keeping it as a second entry would only accumulate junk across
    // repeated trims (see the idempotence test below) for no benefit: this
    // format has no cut identity yet (that's M5f/D60's `schemaVersion`-gated
    // future work), so there's nothing about the redundant entry worth
    // preserving today.
    let edl = EditDecisionList(cuts: [TimeRange(start: 26, end: 28)])
        .trimmed(keeping: TimeRange(start: 5, end: 25), duration: 30)
    #expect(edl.cuts == [TimeRange(start: 0, end: 5), TimeRange(start: 25, end: 30)],
            "the old cut at [26,28) is already covered by the tail bookend [25,30) and must not survive as a separate entry — got \(edl.cuts)")
}

@Test("Running the same trim twice does not accumulate duplicate or overlapping cuts")
func trimIsIdempotentAcrossRepeatedApplication() {
    let range = TimeRange(start: 5, end: 25)
    let once = EditDecisionList(cuts: [TimeRange(start: 10, end: 12), TimeRange(start: 26, end: 28)])
        .trimmed(keeping: range, duration: 30)
    let twice = once.trimmed(keeping: range, duration: 30)
    #expect(twice.cuts == once.cuts,
            "trimming to the same range a second time must reproduce the exact same cuts, not grow the array — once: \(once.cuts), twice: \(twice.cuts)")
}

@Test("Auto-trim's keep range matches the bookends autoTrimCuts computes")
func autoTrimRangeMatchesAutoTrimCutsBookends() throws {
    // `autoTrimRange` is the new factoring the fix introduces: the same
    // first/last-event math `autoTrimCuts` has always done, but returning
    // the KEEP range instead of pre-built cuts, so `AutomationHost` can hand
    // it to `trimmed(keeping:duration:)` and get the identical
    // cuts-preserving merge a manual trim gets. This pins the two functions
    // to agreeing on the same bookends.
    let events = [input(5), input(10), input(20)]
    let range = try EditDecisionList.autoTrimRange(events: events, duration: 30, padding: 0.5)
    let cuts = try EditDecisionList.autoTrimCuts(events: events, duration: 30, padding: 0.5)
    #expect(range == TimeRange(start: 4.5, end: 20.5))
    #expect(cuts == [TimeRange(start: 0, end: range.start), TimeRange(start: range.end, end: 30)])
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

@Test("Auto-trim's first/last are the earliest/latest input event, not the first/last LOGGED")
func autoTrimSortsBeforeTakingBookends() throws {
    // `events.json` happens to always be written in timestamp order today,
    // so every OTHER test here passes whether or not `autoTrimCuts` sorts
    // its input — the `.sorted()` call in `EditDecisionList.autoTrimCuts`
    // reads as redundant against every checked-in fixture and is one
    // "cleanup" away from being deleted by a future reader. This fixture
    // deliberately arrives with the LATEST event first and the EARLIEST
    // event last, so it fails against an implementation that takes
    // `events.first`/`events.last` (or otherwise skips sorting) instead of
    // the true min/max by time: an unsorted read would compute bookends
    // from event 20 first/last (whichever position "first"/"last" landed
    // in), not the actual 5...20 span.
    let cuts = try EditDecisionList.autoTrimCuts(
        events: [input(20), input(5), input(10)], duration: 30, padding: 0.5)
    #expect(cuts == [TimeRange(start: 0, end: 4.5), TimeRange(start: 20.5, end: 30)])
}
