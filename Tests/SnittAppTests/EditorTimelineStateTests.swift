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
/// lands near `target` or `timeout` elapses — `EditorTimelineState.onTrim`
/// applies the new EDL on a detached `Task`, so a caller that just trimmed
/// needs to wait for that rebuild before the next assertion (or the next
/// drag, in `secondTrimRemovesADistinctRegion` below) sees its effect.
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
/// geometry) through the real `EditorTimelineState.onTrim`/`displayState`,
/// exactly as `TimelineViewRepresentable` wires them in production — not a
/// reimplementation of the arithmetic — so a regression to feeding the view
/// the trimmed duration fails here.
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
        view.onTrim = { [weak state] in state?.onTrim($0) }

        // Mirrors `TimelineViewRepresentable.updateNSView`: feed the view
        // whatever `displayState` currently says. Before any trim, that is
        // the full 8s source duration.
        func refreshView() {
            let display = state.displayState(playhead: 0)
            view.update(duration: display.duration, cuts: display.cuts,
                        jumpPoints: display.jumpPoints, playhead: display.playhead)
        }
        refreshView()

        // First drag: the left quarter of an 800px/8s view — source 0..2s.
        view.mouseDown(with: .synthetic(at: NSPoint(x: 0, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 200, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 200, y: 20), in: view))

        let firstCut = try #require(state.edl.cuts.first)
        #expect(abs(firstCut.start - 0.0) < 0.05)
        #expect(abs(firstCut.end - 2.0) < 0.05)

        // Let the rebuild from the first trim land, THEN refresh the view —
        // giving the bug every chance to reintroduce itself: if the view
        // were fed the (now-changed) trimmed duration instead of the source
        // duration, this refresh is exactly where that would happen.
        await waitForDuration(controller, toApproach: sourceSeconds - 2.0)
        refreshView()

        // Second drag on the SAME view: source 4..6s — a region distinct
        // from the first cut. On the bug, the view's axis had shrunk to the
        // 6s trimmed duration, so this same pixel range (400..600 of 800px)
        // would compute against a 6s clock instead of 8s and land at a
        // different, already-partly-cut position.
        view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 600, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 600, y: 20), in: view))

        #expect(state.edl.cuts.count == 2)
        let secondCut = try #require(state.edl.cuts.last)
        #expect(abs(secondCut.start - 4.0) < 0.05)
        #expect(abs(secondCut.end - 6.0) < 0.05)
        // The two cuts must be genuinely distinct regions, not the same
        // range recorded twice.
        #expect(firstCut != secondCut)

        // Duration falls a SECOND time: 8s source, two 2s cuts removed ->
        // 4s of output. On the bug, the second cut lands inside the region
        // the first cut already removed and the composition rebuild leaves
        // duration unchanged after the first drop to 6s.
        await waitForDuration(controller, toApproach: sourceSeconds - 4.0)
        #expect(abs(controller.durationSeconds - (sourceSeconds - 4.0)) < 0.2)
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
    @Test("Clicking inside a cut seeks to the nearest kept edge rather than doing nothing")
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
        view.onTrim = { [weak state] in state?.onTrim($0) }
        view.update(duration: sourceSeconds, cuts: [], jumpPoints: [], playhead: 0)

        // Cut source 2-4s: x200 -> x400 on an 800px view of an 8s source.
        view.mouseDown(with: .synthetic(at: NSPoint(x: 200, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
        await waitForDuration(controller, toApproach: sourceSeconds - 2.0)

        view.update(duration: sourceSeconds, cuts: state.edl.cuts, jumpPoints: [], playhead: 0)
        await controller.seek(toSeconds: 0)

        // x300 is source 3.0s — squarely inside the removed 2-4s region.
        view.mouseDown(with: .synthetic(at: NSPoint(x: 300, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 300, y: 20), in: view))

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
}
