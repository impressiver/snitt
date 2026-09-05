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
}
