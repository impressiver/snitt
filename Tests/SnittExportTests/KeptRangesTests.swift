import Testing
@testable import SnittExport
import SnittDocument

@Test("No cuts keeps the whole recording")
func noCutsKeepsEverything() {
    #expect(KeptRanges.compute(duration: 10, cuts: []) == [TimeRange(start: 0, end: 10)])
}

@Test("A head and tail cut keeps the middle — the auto-trim shape")
func headAndTailCut() {
    let kept = KeptRanges.compute(duration: 30, cuts: [
        TimeRange(start: 0, end: 5),
        TimeRange(start: 25, end: 30),
    ])
    #expect(kept == [TimeRange(start: 5, end: 25)])
}

@Test("A middle cut splits the recording into two kept ranges")
func middleCutSplits() {
    let kept = KeptRanges.compute(duration: 30, cuts: [TimeRange(start: 10, end: 20)])
    #expect(kept == [TimeRange(start: 0, end: 10), TimeRange(start: 20, end: 30)])
}

@Test("Overlapping cuts merge instead of producing a negative range")
func overlappingCutsMerge() {
    // Trimming twice is normal. Naively subtracting each cut in turn produces
    // a range whose end precedes its start, which AVFoundation accepts and
    // then renders as garbage.
    let kept = KeptRanges.compute(duration: 30, cuts: [
        TimeRange(start: 5, end: 15),
        TimeRange(start: 10, end: 20),
    ])
    #expect(kept == [TimeRange(start: 0, end: 5), TimeRange(start: 20, end: 30)])
}

@Test("Unsorted cuts are handled — callers are not required to sort")
func unsortedCuts() {
    let kept = KeptRanges.compute(duration: 30, cuts: [
        TimeRange(start: 25, end: 30),
        TimeRange(start: 0, end: 5),
    ])
    #expect(kept == [TimeRange(start: 5, end: 25)])
}

@Test("Cutting everything keeps nothing, rather than one impossible range")
func cuttingEverythingKeepsNothing() {
    // The caller must be able to detect this and refuse — an empty export is
    // worse than an error, because it looks like it worked.
    #expect(KeptRanges.compute(duration: 10, cuts: [TimeRange(start: 0, end: 10)]).isEmpty)
}

@Test("A cut running past the end is clamped, not extrapolated")
func cutBeyondEndIsClamped() {
    let kept = KeptRanges.compute(duration: 10, cuts: [TimeRange(start: 8, end: 999)])
    #expect(kept == [TimeRange(start: 0, end: 8)])
}

@Test("A zero-length cut changes nothing")
func zeroLengthCutIsInert() {
    #expect(KeptRanges.compute(duration: 10, cuts: [TimeRange(start: 5, end: 5)])
            == [TimeRange(start: 0, end: 10)])
}
