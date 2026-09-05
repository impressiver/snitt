import Testing
@testable import SnittDocument

/// `TimeRangeMapping.trimmedTime(of:keptRanges:)` is already exercised
/// indirectly through `MarkerJumpPointsTests`. These tests target its
/// inverse, `sourceTime(ofTrimmedTime:keptRanges:)`, added for M4b
/// whole-branch review Critical finding #1: the editor timeline needs to map
/// the player's trimmed-time playhead (and its already-trimmed jump points)
/// back onto the source clock the view now draws on.
struct TimeRangeMappingTests {
    @Test("With nothing cut, trimmed time and source time are the same")
    func noCutsIsIdentity() {
        let kept = [TimeRange(start: 0, end: 10)]
        #expect(TimeRangeMapping.sourceTime(ofTrimmedTime: 4.0, keptRanges: kept) == 4.0)
        // The final instant is closed at both ends, matching the forward
        // mapping's own boundary rule.
        #expect(TimeRangeMapping.sourceTime(ofTrimmedTime: 10.0, keptRanges: kept) == 10.0)
    }

    @Test("A trimmed instant after a cut maps back past the cut")
    func mapsPastAnEarlierCut() {
        // Source recording: [0,4) kept, [4,6) cut, [6,10] kept — the trimmed
        // timeline is 8s long: [0,4) from the first range, [4,8] from the
        // second. A naive implementation that just returns its input
        // unchanged (mistaking this for the identity function) passes the
        // no-cuts test above but fails here, since 5.0 unchanged is not 7.0.
        let kept = [TimeRange(start: 0, end: 4), TimeRange(start: 6, end: 10)]
        // Trimmed 3.0 sits inside the first kept range: maps straight through.
        #expect(TimeRangeMapping.sourceTime(ofTrimmedTime: 3.0, keptRanges: kept) == 3.0)
        // Trimmed 5.0 is 1s into the second kept span (cursor 4, length 4),
        // which starts at source 6 — so source 7.0.
        let mapped = try! #require(TimeRangeMapping.sourceTime(ofTrimmedTime: 5.0, keptRanges: kept))
        #expect(abs(mapped - 7.0) < 0.0001)
        // The trimmed timeline's own final instant maps to the source
        // recording's final instant.
        let end = try! #require(TimeRangeMapping.sourceTime(ofTrimmedTime: 8.0, keptRanges: kept))
        #expect(abs(end - 10.0) < 0.0001)
    }

    @Test("Out-of-range trimmed times and an empty range list map to nothing")
    func outOfRangeAndEmptyMapToNil() {
        let kept = [TimeRange(start: 0, end: 4)]
        #expect(TimeRangeMapping.sourceTime(ofTrimmedTime: -1.0, keptRanges: kept) == nil)
        #expect(TimeRangeMapping.sourceTime(ofTrimmedTime: 4.01, keptRanges: kept) == nil)
        #expect(TimeRangeMapping.sourceTime(ofTrimmedTime: 1.0, keptRanges: []) == nil)
    }

    @Test("trimmedTime and sourceTime round-trip through a cut")
    func roundTripsThroughACut() {
        // The property that actually matters: whatever `trimmedTime` sends a
        // source instant to, `sourceTime` must send back to where it started
        // — for every kept instant, not just ones that happen to avoid the
        // cut. This is the wiring the editor's playhead mapping depends on.
        let kept = [TimeRange(start: 0, end: 4), TimeRange(start: 6, end: 10)]
        for source in [0.0, 1.5, 3.9999, 6.0, 7.25, 10.0] {
            let trimmed = try! #require(
                TimeRangeMapping.trimmedTime(of: source, keptRanges: kept))
            let roundTripped = try! #require(
                TimeRangeMapping.sourceTime(ofTrimmedTime: trimmed, keptRanges: kept))
            #expect(abs(roundTripped - source) < 0.0001)
        }
    }
}
