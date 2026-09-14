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
struct VoiceoverPlacementTests {

    private let whole = [TimeRange(start: 0, end: 60)]

    // MARK: - Recording: output time in, source spans out

    @Test("With nothing cut, narration covers the source it was spoken over")
    func uncutIsOneSpan() {
        let segments = VoiceoverPlacement.segments(
            outputStart: 10, duration: 5, keptRanges: whole)
        #expect(segments == [VoiceoverSegment(voiceoverStart: 0, sourceStart: 10,
                                              durationSeconds: 5)])
    }

    @Test("Narration recorded after an earlier cut anchors to the SOURCE it is over")
    func earlierCutShiftsTheAnchor() {
        // Ten seconds already removed from the front, so output 10 IS source
        // 20. Storing the output number would put this narration over the
        // wrong footage the moment anything else changed.
        let kept = [TimeRange(start: 0, end: 10), TimeRange(start: 20, end: 60)]
        let segments = VoiceoverPlacement.segments(
            outputStart: 15, duration: 4, keptRanges: kept)
        #expect(segments == [VoiceoverSegment(voiceoverStart: 0, sourceStart: 25,
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
        let segments = VoiceoverPlacement.segments(
            outputStart: 8, duration: 5, keptRanges: kept)
        #expect(segments == [
            VoiceoverSegment(voiceoverStart: 0, sourceStart: 8, durationSeconds: 2),
            VoiceoverSegment(voiceoverStart: 2, sourceStart: 20, durationSeconds: 3),
        ])
        // The audio itself is continuous: every second is accounted for
        // exactly once, and the offsets into the file run without a gap.
        #expect(segments.map(\.durationSeconds).reduce(0, +) == 5)
        #expect(segments[1].voiceoverStart == segments[0].voiceoverEnd)
    }

    @Test("Narration running past the end of the recording is clipped, not dropped")
    func narrationPastTheEndIsClipped() {
        // Talking over the last second and carrying on after it stops is
        // ordinary. Keeping only what has footage under it is the anchoring
        // rule applied at the end as well as in the middle.
        let segments = VoiceoverPlacement.segments(
            outputStart: 58, duration: 10, keptRanges: whole)
        #expect(segments == [VoiceoverSegment(voiceoverStart: 0, sourceStart: 58,
                                              durationSeconds: 2)])
    }

    @Test("Zero-length narration produces nothing")
    func zeroDurationIsEmpty() {
        #expect(VoiceoverPlacement.segments(outputStart: 5, duration: 0,
                                            keptRanges: whole).isEmpty)
    }

    // MARK: - Playback: source spans back into the current timeline

    private func track(_ segments: [VoiceoverSegment], duration: Double = 30) -> VoiceoverTrack {
        VoiceoverTrack(filename: "voiceover.m4a", durationSeconds: duration, segments: segments)
    }

    @Test("Unchanged edit: narration plays exactly where it was spoken")
    func roundTripsThroughAnUnchangedEdit() {
        let segments = VoiceoverPlacement.segments(
            outputStart: 12, duration: 6, keptRanges: whole)
        let spans = VoiceoverPlacement.outputSpans(of: track(segments), keptRanges: whole)
        #expect(spans == [VoiceoverOutputSpan(voiceoverStart: 0, outputStart: 12,
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
        let segments = VoiceoverPlacement.segments(
            outputStart: 30, duration: 6, keptRanges: whole)
        let afterCut = [TimeRange(start: 10, end: 60)]
        let spans = VoiceoverPlacement.outputSpans(of: track(segments), keptRanges: afterCut)
        #expect(spans == [VoiceoverOutputSpan(voiceoverStart: 0, outputStart: 20,
                                              durationSeconds: 6)])
    }

    @Test("Cutting the footage UNDER narration takes that narration too")
    func cuttingUnderNarrationRemovesIt() {
        let segments = VoiceoverPlacement.segments(
            outputStart: 30, duration: 6, keptRanges: whole)
        let afterCut = [TimeRange(start: 0, end: 30), TimeRange(start: 36, end: 60)]
        #expect(VoiceoverPlacement.outputSpans(of: track(segments),
                                               keptRanges: afterCut).isEmpty)
    }

    @Test("Cutting THROUGH narration keeps the half that still has footage")
    func partialCutClipsRatherThanDrops() {
        // Half a sentence surviving is the honest result of cutting through
        // narration. Dropping the whole segment would silently remove speech
        // that sits over footage still on screen — a bigger, quieter edit than
        // the one that was asked for.
        let segments = VoiceoverPlacement.segments(
            outputStart: 30, duration: 6, keptRanges: whole)
        let afterCut = [TimeRange(start: 0, end: 33), TimeRange(start: 36, end: 60)]
        let spans = VoiceoverPlacement.outputSpans(of: track(segments), keptRanges: afterCut)
        #expect(spans == [VoiceoverOutputSpan(voiceoverStart: 0, outputStart: 30,
                                              durationSeconds: 3)])
    }

    @Test("Undoing the cut brings the narration back")
    func narrationSurvivesAnUndoneCut() {
        // Nothing is destroyed: the audio file is never trimmed and `segments`
        // is never rewritten, so restoring the footage restores the narration.
        // §4.5's non-destructive rule applying to narration for free.
        let segments = VoiceoverPlacement.segments(
            outputStart: 30, duration: 6, keptRanges: whole)
        let subject = track(segments)
        let cut = [TimeRange(start: 0, end: 30), TimeRange(start: 36, end: 60)]
        #expect(VoiceoverPlacement.outputSpans(of: subject, keptRanges: cut).isEmpty)
        #expect(VoiceoverPlacement.outputSpans(of: subject, keptRanges: whole).count == 1)
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
        let segments = VoiceoverPlacement.segments(
            outputStart: 8, duration: 5, keptRanges: kept)
        let spans = VoiceoverPlacement.outputSpans(of: track(segments), keptRanges: whole)

        #expect(spans.count == 2)
        #expect(spans[0].outputStart == 8)
        #expect(spans[1].outputStart == 20, "the second half left the footage it was spoken over")
        // The FILE is still continuous — nothing was destroyed, and the two
        // halves are still consecutive audio. Only where they play moved.
        #expect(spans[1].voiceoverStart == spans[0].voiceoverStart + spans[0].durationSeconds)
    }

    @Test("Spans come back in output order")
    func spansAreOrdered() {
        // The exporter inserts them in the order given, so an unsorted result
        // would place later narration before earlier narration.
        let segments = [
            VoiceoverSegment(voiceoverStart: 4, sourceStart: 40, durationSeconds: 2),
            VoiceoverSegment(voiceoverStart: 0, sourceStart: 5, durationSeconds: 2),
        ]
        let spans = VoiceoverPlacement.outputSpans(of: track(segments), keptRanges: whole)
        #expect(spans.map(\.outputStart) == [5, 40])
    }

    @Test("Everything cut away leaves nothing to play")
    func noKeptRangesMeansNoSpans() {
        let segments = VoiceoverPlacement.segments(
            outputStart: 0, duration: 5, keptRanges: whole)
        #expect(VoiceoverPlacement.outputSpans(of: track(segments), keptRanges: []).isEmpty)
    }
}
