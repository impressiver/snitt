// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// Where narration recorded after the fact actually plays (D93).
///
/// The decision this encodes: **narration is anchored to the FOOTAGE**. A cut
/// takes the narration sitting over the removed picture with it, and everything
/// else stays aligned with the frames it describes. The rejected alternative —
/// anchoring to the finished timeline — keeps the audio continuous and lets the
/// picture slide underneath, so narration that described one thing silently
/// ends up over another.
///
/// Every test with a cut in it exists because uncut, output and source are the
/// same number and an implementation that confused them would pass.
struct OverdubPlacementTests {

    private let whole = [TimeRange(start: 0, end: 60)]

    // MARK: - Recording: output time in, source spans out

    @Test("With nothing cut, narration covers the source it was spoken over")
    func uncutIsOneSpan() {
        let segments = OverdubPlacement.segments(
            outputStart: 10, duration: 5, keptRanges: whole)
        #expect(segments == [OverdubSegment(takeStart: 0, sourceStart: 10,
                                              durationSeconds: 5)])
    }

    @Test("Narration recorded after an earlier cut anchors to the SOURCE it is over")
    func earlierCutShiftsTheAnchor() {
        // Ten seconds already removed from the front, so output 10 IS source
        // 20. Storing the output number would put this narration over the
        // wrong footage the moment anything else changed.
        let kept = [TimeRange(start: 0, end: 10), TimeRange(start: 20, end: 60)]
        let segments = OverdubPlacement.segments(
            outputStart: 15, duration: 4, keptRanges: kept)
        #expect(segments == [OverdubSegment(takeStart: 0, sourceStart: 25,
                                              durationSeconds: 4)])
    }

    @Test("Narration spoken ACROSS a cut splits into two spans")
    func narrationAcrossACutSplits() {
        // It played as five continuous seconds, over footage that is not
        // continuous. One span would have to pretend the removed footage was
        // still there — and that is the thing the anchoring decision rules
        // out, because a cut the narration ran over is a place it must not
        // describe.
        let kept = [TimeRange(start: 0, end: 10), TimeRange(start: 20, end: 60)]
        let segments = OverdubPlacement.segments(
            outputStart: 8, duration: 5, keptRanges: kept)
        #expect(segments == [
            OverdubSegment(takeStart: 0, sourceStart: 8, durationSeconds: 2),
            OverdubSegment(takeStart: 2, sourceStart: 20, durationSeconds: 3),
        ])
        // The audio itself is continuous: every second is accounted for
        // exactly once, and the offsets into the file run without a gap.
        #expect(segments.map(\.durationSeconds).reduce(0, +) == 5)
        #expect(segments[1].takeStart == segments[0].takeEnd)
    }

    @Test("Narration running past the end of the recording is clipped, not dropped")
    func narrationPastTheEndIsClipped() {
        // Talking over the last second and carrying on after it stops is
        // ordinary. Keeping only what has footage under it is the anchoring
        // rule applied at the end as well as in the middle.
        let segments = OverdubPlacement.segments(
            outputStart: 58, duration: 10, keptRanges: whole)
        #expect(segments == [OverdubSegment(takeStart: 0, sourceStart: 58,
                                              durationSeconds: 2)])
    }

    @Test("Zero-length narration produces nothing")
    func zeroDurationIsEmpty() {
        #expect(OverdubPlacement.segments(outputStart: 5, duration: 0,
                                            keptRanges: whole).isEmpty)
    }

    // MARK: - Playback: source spans back into the current timeline

    private func track(_ segments: [OverdubSegment], duration: Double = 30) -> Overdub {
        Overdub(filename: "voiceover.m4a", durationSeconds: duration, segments: segments)
    }

    @Test("Unchanged edit: narration plays exactly where it was spoken")
    func roundTripsThroughAnUnchangedEdit() {
        let segments = OverdubPlacement.segments(
            outputStart: 12, duration: 6, keptRanges: whole)
        let spans = OverdubPlacement.outputSpans(of: track(segments), keptRanges: whole)
        #expect(spans == [OverdubOutputSpan(takeStart: 0, outputStart: 12,
                                              durationSeconds: 6)])
    }

    @Test("A LATER cut elsewhere moves the narration with its footage")
    func laterCutMovesNarrationWithThePicture() {
        // The whole point. Narration was spoken over source 30-36. Cutting
        // 0-10 afterwards slides that footage to output 20-26, and the
        // narration goes with it — still over the frames it describes.
        //
        // Anchoring to the timeline would have left it at output 30, which by
        // then is different footage entirely.
        let segments = OverdubPlacement.segments(
            outputStart: 30, duration: 6, keptRanges: whole)
        let afterCut = [TimeRange(start: 10, end: 60)]
        let spans = OverdubPlacement.outputSpans(of: track(segments), keptRanges: afterCut)
        #expect(spans == [OverdubOutputSpan(takeStart: 0, outputStart: 20,
                                              durationSeconds: 6)])
    }

    @Test("Cutting the footage UNDER narration takes that narration too")
    func cuttingUnderNarrationRemovesIt() {
        let segments = OverdubPlacement.segments(
            outputStart: 30, duration: 6, keptRanges: whole)
        let afterCut = [TimeRange(start: 0, end: 30), TimeRange(start: 36, end: 60)]
        #expect(OverdubPlacement.outputSpans(of: track(segments),
                                               keptRanges: afterCut).isEmpty)
    }

    @Test("Cutting THROUGH narration keeps the half that still has footage")
    func partialCutClipsRatherThanDrops() {
        // Half a sentence surviving is the honest result of cutting through
        // narration. Dropping the whole segment would silently remove speech
        // that sits over footage still on screen — a bigger, quieter edit than
        // the one that was asked for.
        let segments = OverdubPlacement.segments(
            outputStart: 30, duration: 6, keptRanges: whole)
        let afterCut = [TimeRange(start: 0, end: 33), TimeRange(start: 36, end: 60)]
        let spans = OverdubPlacement.outputSpans(of: track(segments), keptRanges: afterCut)
        #expect(spans == [OverdubOutputSpan(takeStart: 0, outputStart: 30,
                                              durationSeconds: 3)])
    }

    @Test("Undoing the cut brings the narration back")
    func narrationSurvivesAnUndoneCut() {
        // Nothing is destroyed: the audio file is never trimmed and `segments`
        // is never rewritten, so restoring the footage restores the narration.
        // §4.5's non-destructive rule applying to narration for free.
        let segments = OverdubPlacement.segments(
            outputStart: 30, duration: 6, keptRanges: whole)
        let subject = track(segments)
        let cut = [TimeRange(start: 0, end: 30), TimeRange(start: 36, end: 60)]
        #expect(OverdubPlacement.outputSpans(of: subject, keptRanges: cut).isEmpty)
        #expect(OverdubPlacement.outputSpans(of: subject, keptRanges: whole).count == 1)
    }

    @Test("Restoring footage narration was spoken ACROSS pulls the two halves apart")
    func restoringFootageSeparatesSplitNarration() {
        // The cost of anchoring to the footage, stated rather than hidden.
        //
        // Narration spoken across an existing cut plays as one unbroken
        // sentence. Undoing that cut puts ten seconds of picture back BETWEEN
        // its two halves, and each half stays with the frames it describes —
        // so the sentence now has a ten-second hole in it.
        //
        // That is the same rule as every other test here, applied in the
        // direction nobody thinks about first. The alternative is narration
        // that keeps playing over footage it was never spoken about, which is
        // the failure this model exists to avoid. I wrote this test expecting
        // the halves to re-join, which would have required exactly that.
        let kept = [TimeRange(start: 0, end: 10), TimeRange(start: 20, end: 60)]
        let segments = OverdubPlacement.segments(
            outputStart: 8, duration: 5, keptRanges: kept)
        let spans = OverdubPlacement.outputSpans(of: track(segments), keptRanges: whole)

        #expect(spans.count == 2)
        #expect(spans[0].outputStart == 8)
        #expect(spans[1].outputStart == 20, "the second half left the footage it was spoken over")
        // The FILE is still continuous — nothing was destroyed, and the two
        // halves are still consecutive audio. Only where they play moved.
        #expect(spans[1].takeStart == spans[0].takeStart + spans[0].durationSeconds)
    }

    @Test("Spans come back in output order")
    func spansAreOrdered() {
        // The exporter inserts them in the order given, so an unsorted result
        // would place later narration before earlier narration.
        let segments = [
            OverdubSegment(takeStart: 4, sourceStart: 40, durationSeconds: 2),
            OverdubSegment(takeStart: 0, sourceStart: 5, durationSeconds: 2),
        ]
        let spans = OverdubPlacement.outputSpans(of: track(segments), keptRanges: whole)
        #expect(spans.map(\.outputStart) == [5, 40])
    }

    @Test("Everything cut away leaves nothing to play")
    func noKeptRangesMeansNoSpans() {
        let segments = OverdubPlacement.segments(
            outputStart: 0, duration: 5, keptRanges: whole)
        #expect(OverdubPlacement.outputSpans(of: track(segments), keptRanges: []).isEmpty)
    }
}

/// Placing a narrated WORD on the capture's clock.
///
/// The transcript is the only consumer: narration is recognised against
/// `voiceover.m4a`, so its words come back timed from the start of that file
/// while every other word is timed against the capture. Unmapped, narration
/// appears at the beginning of the recording and drifts further from the
/// picture the later it was spoken.
struct VoiceoverWordTimeTests {

    private func track(_ segments: [OverdubSegment]) -> Overdub {
        Overdub(filename: "voiceover.m4a", durationSeconds: 60, segments: segments)
    }

    @Test("A word's time moves from the FILE's clock to the capture's")
    func wordMovesToSourceTime() {
        // Narration recorded over source 30: second 0 of the file is source
        // 30, not source 0.
        let subject = track([OverdubSegment(takeStart: 0, sourceStart: 30,
                                              durationSeconds: 10)])
        #expect(OverdubPlacement.sourceTime(ofTakeTime: 0, in: subject) == 30)
        #expect(OverdubPlacement.sourceTime(ofTakeTime: 4.5, in: subject) == 34.5)
    }

    @Test("A word after a split lands over ITS footage, not the first segment's")
    func wordAfterASplitFollowsItsSegment() {
        // Narration spoken across a cut is continuous in the file and not in
        // the recording. A word two-thirds of the way through belongs to the
        // second stretch of footage, which is somewhere else entirely — the
        // case a single offset cannot express.
        let subject = track([
            OverdubSegment(takeStart: 0, sourceStart: 5, durationSeconds: 2),
            OverdubSegment(takeStart: 2, sourceStart: 40, durationSeconds: 3),
        ])
        #expect(OverdubPlacement.sourceTime(ofTakeTime: 1, in: subject) == 6)
        #expect(OverdubPlacement.sourceTime(ofTakeTime: 2.5, in: subject) == 40.5)
    }

    @Test("A boundary belongs to the segment it STARTS")
    func boundaryBelongsToTheLaterSegment() {
        // Half-open, so one instant cannot be in two places. Closed on both
        // ends, a word at 2.0 would resolve to the first segment's end AND the
        // second's start, and which one won would depend on array order.
        let subject = track([
            OverdubSegment(takeStart: 0, sourceStart: 5, durationSeconds: 2),
            OverdubSegment(takeStart: 2, sourceStart: 40, durationSeconds: 3),
        ])
        #expect(OverdubPlacement.sourceTime(ofTakeTime: 2.0, in: subject) == 40)
    }

    @Test("Narration over footage that has been cut has no place, and says so")
    func wordOverCutFootageIsNil() {
        // Nil rather than a nearby time. A word whose footage is gone belongs
        // nowhere, and placing it at the fold would put narration on a frame
        // it was never spoken about.
        let subject = track([OverdubSegment(takeStart: 0, sourceStart: 5,
                                              durationSeconds: 2)])
        #expect(OverdubPlacement.sourceTime(ofTakeTime: 9, in: subject) == nil)
    }
}

/// A take that was PAUSED and carried on (D102's transport).
///
/// The recorder never stops, so the audio is one continuous file; the output
/// times are not continuous, because nothing stops somebody scrubbing while
/// paused. Getting this wrong misplaces everything after the pause, and it is
/// silent — the file plays, over the wrong footage.
struct PausedTakeTests {

    private let whole = [TimeRange(start: 0, end: 60)]

    @Test("Two runs become two segments, at the two places they were spoken")
    func runsBecomeSegments() {
        let segments = OverdubPlacement.segments(
            runs: [OverdubPlacement.TakeRun(outputStart: 10, durationSeconds: 2),
                   OverdubPlacement.TakeRun(outputStart: 30, durationSeconds: 3)],
            keptRanges: whole)
        #expect(segments.count == 2)
        #expect(segments[0].sourceStart == 10)
        #expect(segments[1].sourceStart == 30)
    }

    @Test("File offsets are CUMULATIVE, because the recorder never stopped")
    func fileOffsetsAccumulate() {
        // The defect this catches is inaudible in a placement check and
        // obvious to a listener: the second run starts two seconds into the
        // file, and reading it from zero replays the first run's words at the
        // second run's position.
        let segments = OverdubPlacement.segments(
            runs: [OverdubPlacement.TakeRun(outputStart: 10, durationSeconds: 2),
                   OverdubPlacement.TakeRun(outputStart: 30, durationSeconds: 3)],
            keptRanges: whole)
        #expect(segments[0].takeStart == 0)
        #expect(segments[1].takeStart == 2, "the second run reads from \(segments[1].takeStart)")
    }

    @Test("A run that overhangs the footage still consumes its own audio")
    func overhangingRunStillAdvancesTheOffset() {
        // Charging only the PLACED part would slide every later run earlier in
        // the file — so a take paused after running past the end would come
        // back mid-word.
        let short = [TimeRange(start: 0, end: 11)]
        let segments = OverdubPlacement.segments(
            runs: [OverdubPlacement.TakeRun(outputStart: 10, durationSeconds: 5),
                   OverdubPlacement.TakeRun(outputStart: 5, durationSeconds: 2)],
            keptRanges: short)
        let second = segments.last
        #expect(second?.takeStart == 5,
                "the second run reads from \(String(describing: second?.takeStart)) of 5")
    }

    @Test("A single run is placed exactly as an unpaused take")
    func oneRunMatchesTheSimpleForm() {
        // One arithmetic either way. Two rules for "where does this audio go"
        // is how a paused take and an unpaused one start disagreeing.
        let viaRuns = OverdubPlacement.segments(
            runs: [OverdubPlacement.TakeRun(outputStart: 12, durationSeconds: 4)],
            keptRanges: whole)
        let direct = OverdubPlacement.segments(outputStart: 12, duration: 4, keptRanges: whole)
        #expect(viaRuns == direct)
    }

    @Test("A run split by a cut still splits, and the next run follows it")
    func runsAndCutsCompose() {
        // Both mechanisms at once, which is where an offset bug hides: the
        // first run is broken in two by a cut, so the second run's file offset
        // has to be its own length rather than the number of segments before
        // it.
        let kept = [TimeRange(start: 0, end: 10), TimeRange(start: 20, end: 40)]
        let segments = OverdubPlacement.segments(
            runs: [OverdubPlacement.TakeRun(outputStart: 8, durationSeconds: 4),
                   OverdubPlacement.TakeRun(outputStart: 15, durationSeconds: 2)],
            keptRanges: kept)
        #expect(segments.count == 3, "got \(segments.count) segments")
        #expect(segments[2].takeStart == 4,
                "the second run reads from \(segments[2].takeStart) rather than 4")
    }

    @Test("No runs is no segments")
    func noRuns() {
        #expect(OverdubPlacement.segments(runs: [], keptRanges: whole).isEmpty)
    }

    @Test("A zero-length run contributes nothing and shifts nothing")
    func emptyRunIsHarmless() {
        // A pause pressed immediately after resuming.
        let segments = OverdubPlacement.segments(
            runs: [OverdubPlacement.TakeRun(outputStart: 10, durationSeconds: 2),
                   OverdubPlacement.TakeRun(outputStart: 20, durationSeconds: 0),
                   OverdubPlacement.TakeRun(outputStart: 30, durationSeconds: 1)],
            keptRanges: whole)
        #expect(segments.count == 2)
        #expect(segments[1].takeStart == 2, "an empty run moved the file offset")
    }
}
