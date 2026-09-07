import AppKit
import AVFoundation
@testable import SnittApp
import SnittDocument
import SnittExport
import Testing

/// A tiny bundle with a real, loadable `capture.mov` — just what
/// `CompositionBuilder.build` and `CompositionBuilder.mediaDuration` need.
/// Duplicated rather than shared: Swift Testing target sources don't share
/// PRIVATE helpers across files (see `PreviewControllerTests.swift`'s own
/// `makeTestBundle`), so this file gets its own thin wrapper around the
/// target-shared `writeSyntheticMovie` (`SyntheticMovie.swift`, not
/// `private`, so it IS visible here).
@MainActor
private func makeTimelineStateTestBundle(seconds: Double) async throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds)
    return bundle
}

/// Polls `controller.durationSeconds` (the TRIMMED/output duration) until it
/// lands near `target` or `timeout` elapses — `EditorTimelineState.cutSelection`
/// (`onTrim`, pre-M5f-Task-4) applies the new EDL on a detached `Task`, so a
/// caller that just cut a selection needs to wait for that rebuild before the
/// next assertion (or the next drag, in `secondTrimRemovesADistinctRegion`
/// below) sees its effect.
@MainActor
private func waitForDuration(_ controller: PreviewController, toApproach target: Double,
                              timeout: Double = 5.0) async {
    var waited = 0.0
    while abs(controller.durationSeconds - target) > 0.2, waited < timeout {
        try? await Task.sleep(nanoseconds: 20_000_000)
        waited += 0.02
    }
}

/// M4b whole-branch review, Critical finding #1: the timeline view and the
/// EDL used to run on different clocks. `updateNSView` fed the view
/// `controller.durationSeconds` — the TRIMMED (output) duration — while
/// `edl.cuts` are consumed as SOURCE-time ranges. After the first trim, the
/// view's axis was output time and every subsequent drag appended an
/// output-time range into a source-time list: a second drag on the same
/// 800px view landed inside the already-removed region and did nothing.
///
/// These tests drive the real `TimelineView` (mouse events, real pixel
/// geometry) through the real `EditorTimelineState.onSelect`/`displayState`,
/// exactly as `TimelineViewRepresentable` wires them in production — not a
/// reimplementation of the arithmetic — so a regression to feeding the view
/// the trimmed duration fails here.
///
/// D56 (M5f Task 4) split what used to be a single `onTrim` into
/// `onSelect` (a drag only replaces `state.selection`) plus
/// `cutSelection()` (turns it into a `Cut`). Every drag below is followed
/// by an explicit `cutSelection()` call — the equivalent, post-split,
/// two-step way of driving the exact same "drag a cut into existence"
/// scenario these tests were written to pin.
@MainActor
struct EditorTimelineStateTests {
    @Test("A second trim in the same session removes a distinct region, and duration falls twice")
    func secondTrimRemovesADistinctRegion() async throws {
        let sourceSeconds = 8.0
        let bundle = try await makeTimelineStateTestBundle(seconds: sourceSeconds)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: EditDecisionList(), events: [])

        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.onScrub = { [weak state] in state?.onScrub($0) }
        view.onSelect = { [weak state] in state?.onSelect($0) }

        // Mirrors `TimelineViewRepresentable.updateNSView`: feed the view
        // whatever `displayState` currently says. Before any trim, that is
        // the full 8s source duration.
        func refreshView() {
            let display = state.displayState(playhead: 0)
            view.update(duration: display.duration, cuts: display.cuts,
                        jumpPoints: display.jumpPoints, playhead: display.playhead,
                        selection: display.selection)
        }
        refreshView()

        // First drag: the left quarter of an 800px/8s view — source 0..2s.
        // The drag only selects (D56) — cutting it is a deliberate second
        // step, exactly as a person pressing Cut after dragging would do.
        view.mouseDown(with: .synthetic(at: NSPoint(x: 0, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 200, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 200, y: 20), in: view))
        #expect(state.edl.cuts.isEmpty)   // the drag alone must not cut
        state.cutSelection()

        let firstCut = try #require(state.edl.cuts.first)
        #expect(abs(firstCut.range.start - 0.0) < 0.05)
        #expect(abs(firstCut.range.end - 2.0) < 0.05)

        // Let the rebuild from the first trim land, THEN refresh the view —
        // giving the bug every chance to reintroduce itself: if the view
        // were fed the (now-changed) trimmed duration instead of the source
        // duration, this refresh is exactly where that would happen.
        await waitForDuration(controller, toApproach: sourceSeconds - 2.0)
        refreshView()

        // Second drag on the SAME view. 800px now shows the 6s of OUTPUT
        // that remain, so pixels 400..600 are output 3.0..4.5 — SOURCE
        // 5.0..6.5, a region distinct from the first cut and, crucially,
        // one that is still there to remove. The pixel range covers 1.5
        // OUTPUT seconds and that is exactly what it must take away.
        //
        // These numbers were 4.0..6.0 until the M5f whole-branch review.
        // That was the arithmetic of a FIXED 8s source gesture scale, which
        // this milestone adopted citing the very M4b finding this test
        // exists for — and which reproduces it: on a scale that never
        // shrinks, the same pixels mean the same source span forever, so a
        // second drag over pixels already cut appends a duplicate `Cut` and
        // removes nothing. `GestureAxisTests
        // .repeatedDragOverTheSamePixelsCutsTwice` is that case stated
        // directly.
        view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 600, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 600, y: 20), in: view))
        #expect(state.edl.cuts.count == 1)   // still just the first — selecting, not cutting
        state.cutSelection()

        #expect(state.edl.cuts.count == 2)
        let secondCut = try #require(state.edl.cuts.last)
        #expect(abs(secondCut.range.start - 5.0) < 0.05)
        #expect(abs(secondCut.range.end - 6.5) < 0.05)
        // The two cuts must be genuinely distinct regions, not the same
        // range recorded twice.
        #expect(firstCut != secondCut)
        // The second cut removed KEPT footage, not ground the first already
        // took: the drag covered 1.5 output seconds, so the output timeline
        // must be exactly 1.5s shorter. This is the property the M4b
        // Critical is about, and it is stated here in the units the person
        // was actually looking at.
        let timebase = Timebase(sourceDuration: sourceSeconds, edl: state.edl)
        #expect(abs(timebase.outputDuration - 4.5) < 0.05)

        // Duration falls a SECOND time. On the bug, the second cut lands
        // inside the region the first cut already removed and the
        // composition rebuild leaves duration unchanged after the first
        // drop to 6s.
        await waitForDuration(controller, toApproach: 4.5)
        #expect(abs(controller.durationSeconds - 4.5) < 0.2)
    }

    /// A click inside a drawn cut region must SEEK, not do nothing.
    ///
    /// `onScrub` maps the view's source-time click into trimmed time before
    /// seeking. `TimeRangeMapping.trimmedTime` returns nil for an instant
    /// inside a cut — honest, since that instant has no frame — and the
    /// first version of this handler simply returned, swallowing the click.
    /// A visibly-drawn region that eats clicks with no feedback is the
    /// silent no-op this project keeps finding, so it now snaps to the
    /// nearest kept edge via `nearestTrimmedTime`.
    ///
    /// This test exists at the STATE level, not against `TimeRangeMapping`,
    /// because the arithmetic was already covered while the wiring was not:
    /// swapping `nearestTrimmedTime` back to `trimmedTime` in `onScrub`
    /// compiled and passed the whole suite.
    ///
    /// It drives the CUT through the real view, then calls `onScrub`
    /// directly with a source instant inside it. Until the M5f whole-branch
    /// review the click could come from the view too — gestures were
    /// interpreted on a fixed source axis that still had the removed
    /// footage on it, so a pixel could land inside a cut. On the output
    /// axis it cannot: removed footage is not drawn, so there is no pixel
    /// pointing at it, and a click at the fold's own pixel is claimed by
    /// `TimelineView.foldHit(atX:)` before scrubbing is considered.
    /// `onScrub`'s snap is therefore a guard for callers handing it a
    /// source instant from somewhere other than a click — and going through
    /// the view for the assertion would now pass against `trimmedTime` too,
    /// which is a test that proves nothing.
    @Test("Scrubbing to an instant inside a cut seeks to the nearest kept edge rather than doing nothing")
    func clickInsideACutStillSeeks() async throws {
        let sourceSeconds = 8.0
        let bundle = try await makeTimelineStateTestBundle(seconds: sourceSeconds)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: EditDecisionList(), events: [])

        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.onScrub = { [weak state] in state?.onScrub($0) }
        view.onSelect = { [weak state] in state?.onSelect($0) }
        view.update(duration: sourceSeconds, cuts: [], jumpPoints: [], playhead: 0)

        // Cut source 2-4s: x200 -> x400 on an 800px view of an 8s source.
        // The drag only selects (D56) — `cutSelection()` is the deliberate
        // second step that actually removes the span.
        view.mouseDown(with: .synthetic(at: NSPoint(x: 200, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        state.cutSelection()
        await waitForDuration(controller, toApproach: sourceSeconds - 2.0)

        view.update(duration: sourceSeconds, cuts: state.edl.cuts, jumpPoints: [], playhead: 0)
        await controller.seek(toSeconds: 0)

        // Source 3.0s — squarely inside the removed 2-4s region, and the
        // one input `trimmedTime` answers `nil` for while
        // `nearestTrimmedTime` answers 2.0. A handler that returns on `nil`
        // leaves the playhead at 0 and this test fails on that alone.
        state.onScrub(3.0)

        var waited = 0.0
        while CMTimeGetSeconds(controller.player.currentTime()) < 1.9, waited < 5.0 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            waited += 0.02
        }
        // Trimmed 2.0s is where the cut sits in the output — the boundary
        // both of its edges collapse onto. Doing nothing leaves the playhead
        // at 0, which is what the un-snapped handler produced.
        #expect(abs(CMTimeGetSeconds(controller.player.currentTime()) - 2.0) < 0.3)
    }

    /// M5f Task 3: `TimelineGeometry` now draws the playhead on the OUTPUT
    /// axis (D56), and `controller.player.currentTime()` already reports
    /// exactly that clock — `CompositionBuilder` only ever builds kept
    /// ranges into the composition, so the player never sees a cut second at
    /// all. `displayState` must therefore hand the incoming playhead through
    /// UNCONVERTED. The prior version of this method (correct while the view
    /// drew on the source axis) mapped it output-to-source instead — with a
    /// [0,2) cut on an 8s recording, an output playhead of 3.0 would come
    /// back as 5.0, landing the drawn playhead a full 2 seconds off the
    /// instant the player is actually showing.
    @Test("displayState reports the playhead as OUTPUT time, unconverted")
    func displayStateReportsPlayheadUnconverted() async throws {
        let sourceSeconds = 8.0
        let bundle = try await makeTimelineStateTestBundle(seconds: sourceSeconds)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: EditDecisionList(), events: [])

        // D56 (M5f Task 4): `onTrim` split into `onSelect` + `cutSelection`;
        // this is the two-step equivalent of the old direct call.
        state.onSelect(Selection(range: TimeRange(start: 0, end: 2)))
        state.cutSelection()
        await waitForDuration(controller, toApproach: sourceSeconds - 2.0)

        let display = state.displayState(playhead: 3.0)
        #expect(display.playhead == 3.0)
    }

    /// The same clock question as `displayStateReportsPlayheadUnconverted`,
    /// for `jumpPoints` instead of the playhead: `controller.jumpPoints` are
    /// already OUTPUT time (`MarkerJumpPoints.compute` builds them straight
    /// from `keptRanges`), so `displayState` must pass them through as-is
    /// rather than mapping them a second time onto source time.
    @Test("displayState reports jump points as OUTPUT time, unconverted")
    func displayStateReportsJumpPointsUnconverted() async throws {
        let sourceSeconds = 8.0
        let bundle = try await makeTimelineStateTestBundle(seconds: sourceSeconds)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let marker = LoggedEvent(timeSeconds: 5.0, kind: .marker, label: "late")
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: EditDecisionList(), events: [marker])

        // Cut source 0-2s: the marker at source 5.0 lands at OUTPUT 3.0.
        // D56 (M5f Task 4): `onTrim` split into `onSelect` + `cutSelection`;
        // this is the two-step equivalent of the old direct call.
        state.onSelect(Selection(range: TimeRange(start: 0, end: 2)))
        state.cutSelection()
        await waitForDuration(controller, toApproach: sourceSeconds - 2.0)

        let display = state.displayState(playhead: 0)
        let jumpPoint = try #require(display.jumpPoints.first)
        // The prior (source-converting) implementation would report 5.0
        // here instead.
        #expect(abs(jumpPoint.timeSeconds - 3.0) < 0.2)
    }
}
