import Testing
@testable import SnittDocument

/// `Timebase` is the typed boundary between `SourceTime` (a position in
/// `capture.mov`) and `OutputTime` (a position in the trimmed
/// composition/export). M4b shipped a defect from conflating the two —
/// a timeline fed output-time durations into code that consumed
/// source-time cuts, so a second trim silently did nothing. These tests
/// exist to keep the conversion itself, not just the types, honest.
struct TimebaseTests {
    @Test("Output time skips cut spans")
    func outputTimeSkipsCuts() {
        // 10s source, one 2s cut at 3s. Output is 8s long.
        let edl = EditDecisionList(cuts: [Cut(range: TimeRange(start: 3, end: 5))])
        let base = Timebase(sourceDuration: 10, edl: edl)

        #expect(base.outputDuration == 8)
        // Before the cut: unchanged.
        #expect(base.outputTime(forSource: SourceTime(2)) == OutputTime(2))
        // After the cut: shifted back by the cut's length.
        #expect(base.outputTime(forSource: SourceTime(6)) == OutputTime(4))
        // Inside the cut: there IS no output time. Returning 0, or the cut's
        // start, or crashing are all wrong in different ways — a caller that
        // asks must be told the span is not in the output.
        #expect(base.outputTime(forSource: SourceTime(4)) == nil)
    }

    @Test("Source time round-trips through output time")
    func roundTrip() {
        let edl = EditDecisionList(cuts: [Cut(range: TimeRange(start: 3, end: 5))])
        let base = Timebase(sourceDuration: 10, edl: edl)
        for t in stride(from: 0.0, to: 10.0, by: 0.25) {
            guard let out = base.outputTime(forSource: SourceTime(t)) else { continue }
            // The property M4b's defect violated: a time that survives the
            // cut must map back to itself. Asserting only one direction
            // passes against an inverse that is subtly wrong (e.g. one that
            // ignores the cut and returns its input unchanged) — every
            // `out` here comes from a successful forward mapping, so the
            // inverse must always succeed too.
            guard let back = base.sourceTime(forOutput: out) else {
                Issue.record("sourceTime(forOutput:) returned nil for \(out), which outputTime(forSource:) itself produced")
                continue
            }
            #expect(abs(back.seconds - t) < 1e-9)
        }
    }

    @Test("With nothing cut, both directions are the identity")
    func noCutsIsIdentity() {
        let base = Timebase(sourceDuration: 10, edl: EditDecisionList.fullRange())
        #expect(base.outputDuration == 10)
        #expect(base.outputTime(forSource: SourceTime(4)) == OutputTime(4))
        #expect(base.sourceTime(forOutput: OutputTime(4)) == SourceTime(4))
        // The shared final instant, closed at both ends on both sides.
        #expect(base.outputTime(forSource: SourceTime(10)) == OutputTime(10))
        #expect(base.sourceTime(forOutput: OutputTime(10)) == SourceTime(10))
    }

    @Test("Cutting everything leaves zero output and no valid position in it")
    func cuttingEverythingLeavesNothing() {
        let edl = EditDecisionList(cuts: [Cut(range: TimeRange(start: 0, end: 10))])
        let base = Timebase(sourceDuration: 10, edl: edl)
        #expect(base.outputDuration == 0)
        // A wrong implementation might invent position 0 as "the output"
        // rather than admit there isn't one.
        #expect(base.outputTime(forSource: SourceTime(5)) == nil)
        #expect(base.sourceTime(forOutput: OutputTime(0)) == nil)
    }

    @Test("Two cuts shift output time by the cumulative amount removed before it")
    func multipleCutsAccumulateShift() {
        // Source: [0,2) kept, [2,4) cut, [4,7) kept, [7,9) cut, [9,10] kept.
        // Output is 2 + 3 + 1 = 6s long.
        let edl = EditDecisionList(cuts: [
            Cut(range: TimeRange(start: 2, end: 4)),
            Cut(range: TimeRange(start: 7, end: 9)),
        ])
        let base = Timebase(sourceDuration: 10, edl: edl)
        #expect(base.outputDuration == 6)
        // Source 9.5 is 0.5s into the final kept range, which starts at
        // output 2 + 3 = 5 — a mutant that only accounts for the FIRST cut
        // would answer 9.5 - 2 = 7.5 instead of 5.5.
        let out = base.outputTime(forSource: SourceTime(9.5))
        #expect(out != nil)
        if let out {
            #expect(abs(out.seconds - 5.5) < 1e-9)
            let back = base.sourceTime(forOutput: out)
            #expect(back != nil)
            if let back {
                #expect(abs(back.seconds - 9.5) < 1e-9)
            }
        }
    }

    @Test("An out-of-range output time maps to nothing, not a clamp")
    func outOfRangeOutputTimeIsNil() {
        let edl = EditDecisionList(cuts: [Cut(range: TimeRange(start: 3, end: 5))])
        let base = Timebase(sourceDuration: 10, edl: edl)
        // outputDuration is 8; both sides of that range are out of bounds.
        #expect(base.sourceTime(forOutput: OutputTime(-1)) == nil)
        #expect(base.sourceTime(forOutput: OutputTime(8.5)) == nil)
    }

    @Test("An out-of-range source time maps to nothing, not a clamp")
    func outOfRangeSourceTimeIsNil() {
        let edl = EditDecisionList(cuts: [Cut(range: TimeRange(start: 3, end: 5))])
        let base = Timebase(sourceDuration: 10, edl: edl)
        // A mutant that clamps an out-of-range source instant to the nearest
        // valid output edge would answer OutputTime(0) / OutputTime(8)
        // (outputDuration) here instead of admitting the query was out of
        // range — the same failure mode outOfRangeOutputTimeIsNil guards on
        // the inverse side, now pinned on the forward side too.
        #expect(base.outputTime(forSource: SourceTime(-1)) == nil)
        #expect(base.outputTime(forSource: SourceTime(10.5)) == nil)
    }

    @Test("outputDuration accounts for overlap and end-clamping, not a naive subtraction")
    func outputDurationIsNotANaiveSum() {
        // Overlapping cuts [2,5] and [4,7] merge into one [2,7] span (3s of
        // source time, not 3+3=6s counted twice). The cut [8,999] is clamped
        // to the recording's own end, [8,10] (2s of source time, not 991s).
        // Kept: [0,2] and [7,8], so outputDuration is 3.
        //
        // A naive `sourceDuration - Σ(raw cut lengths)` computes
        // 10 - (3 + 3 + 991) = -987 — exactly the kind of mistake
        // `KeptRanges.compute` exists to normalise away (its own doc comment
        // names both overlap and past-the-end as routine), and which
        // `outputDuration` must inherit by reducing over the normalised
        // `keptRanges` rather than re-deriving the arithmetic from raw cuts.
        let edl = EditDecisionList(cuts: [
            Cut(range: TimeRange(start: 2, end: 5)),
            Cut(range: TimeRange(start: 4, end: 7)),
            Cut(range: TimeRange(start: 8, end: 999)),
        ])
        let base = Timebase(sourceDuration: 10, edl: edl)
        #expect(base.outputDuration == 3)
    }

    // MARK: - foldPosition(for:) (M5f Task 5: a cut collapses to a fold)

    @Test("An interior cut's fold sits exactly where the kept content before it ends")
    func interiorCutFoldsWhereKeptContentBeforeItEnds() {
        // 10s source, cut [3,5): kept is [0,3] then [5,10]. A wrong
        // implementation might answer the cut's OWN start (3, coincidentally
        // right here) regardless of what precedes it, which the two cases
        // below discriminate from the real "cumulative kept duration"
        // answer.
        let cut = Cut(range: TimeRange(start: 3, end: 5))
        let base = Timebase(sourceDuration: 10, edl: EditDecisionList(cuts: [cut]))
        #expect(base.foldPosition(for: cut) == OutputTime(3))
    }

    @Test("A cut at the very start folds to output 0")
    func headCutFoldsToZero() {
        let cut = Cut(range: TimeRange(start: 0, end: 3))
        let base = Timebase(sourceDuration: 10, edl: EditDecisionList(cuts: [cut]))
        // Nothing is kept before a head cut, so there is nothing to
        // accumulate — the fold sits at the very start of the output, not
        // at the cut's own end (3), which a mutant that returned
        // `cut.range.end` instead of "kept time before it" would produce.
        #expect(base.foldPosition(for: cut) == OutputTime(0))
    }

    @Test("A cut at the very end folds to the full output duration")
    func tailCutFoldsToOutputDuration() {
        let cut = Cut(range: TimeRange(start: 7, end: 10))
        let base = Timebase(sourceDuration: 10, edl: EditDecisionList(cuts: [cut]))
        #expect(base.outputDuration == 7)
        #expect(base.foldPosition(for: cut) == OutputTime(7))
    }

    @Test("Overlapping cuts that merge into one gap fold to the same output instant")
    func overlappingCutsShareAFoldPosition() {
        // [2,5) and [4,7) overlap and merge into one gap [2,7); kept is
        // [0,2] then [7,10]. Both cuts describe the SAME removed span once
        // merged, so both must report the SAME meeting point (2) — a
        // mutant that used each cut's own, un-merged `range.start` naively
        // would still get this right by coincidence for the first cut, but
        // the second cut's own start (4) is a different, wrong answer this
        // discriminates.
        let cutA = Cut(range: TimeRange(start: 2, end: 5))
        let cutB = Cut(range: TimeRange(start: 4, end: 7))
        let base = Timebase(sourceDuration: 10, edl: EditDecisionList(cuts: [cutA, cutB]))
        #expect(base.foldPosition(for: cutA) == OutputTime(2))
        #expect(base.foldPosition(for: cutB) == OutputTime(2))
    }

    @Test("Cutting everything still gives a finite fold position, not a crash")
    func foldPositionWhenEverythingIsCut() {
        let cut = Cut(range: TimeRange(start: 0, end: 10))
        let base = Timebase(sourceDuration: 10, edl: EditDecisionList(cuts: [cut]))
        #expect(base.outputDuration == 0)
        #expect(base.foldPosition(for: cut) == OutputTime(0))
    }
}
