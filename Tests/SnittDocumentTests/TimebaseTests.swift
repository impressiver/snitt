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
        let edl = EditDecisionList(cuts: [TimeRange(start: 3, end: 5)])
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
        let edl = EditDecisionList(cuts: [TimeRange(start: 3, end: 5)])
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
        let edl = EditDecisionList(cuts: [TimeRange(start: 0, end: 10)])
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
            TimeRange(start: 2, end: 4),
            TimeRange(start: 7, end: 9),
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
        let edl = EditDecisionList(cuts: [TimeRange(start: 3, end: 5)])
        let base = Timebase(sourceDuration: 10, edl: edl)
        // outputDuration is 8; both sides of that range are out of bounds.
        #expect(base.sourceTime(forOutput: OutputTime(-1)) == nil)
        #expect(base.sourceTime(forOutput: OutputTime(8.5)) == nil)
    }
}
