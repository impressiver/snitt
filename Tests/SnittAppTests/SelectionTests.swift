import AppKit
@testable import SnittApp
import SnittDocument
import SnittExport
import Testing

/// A tiny bundle with a real, loadable `capture.mov` — just what
/// `CompositionBuilder.build` needs to construct a real `PreviewController`,
/// which `EditorTimelineState`'s initializer requires.
///
/// Duplicated rather than shared with `EditorTimelineStateTests.swift`'s
/// identical-in-spirit helper: Swift Testing target sources don't share
/// PRIVATE helpers across files (see that file's own doc comment, and
/// `PreviewControllerTests.swift`'s `makeTestBundle`), so this file gets its
/// own thin wrapper around the target-shared `writeSyntheticMovie`
/// (`SyntheticMovie.swift`, not `private`, so it IS visible here).
@MainActor
private func makeSelectionTestBundle(seconds: Double) async throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds)
    return bundle
}

/// D56 (M5f Task 4): a drag on the timeline SELECTS; cutting is a separate
/// decision applied to a selection afterwards. Before this task, `TrimGesture`
/// (via `TimelineView.onTrim` / `EditorTimelineState.onTrim`) conflated the
/// two — a drag ending was itself the cut.
///
/// The test that matters here is `dragAloneLeavesTheEDLUnchanged`: a test
/// that only checks a cut exists after "drag, then cut" passes against the
/// OLD conflated behaviour too (a drag that already cut, followed by a
/// cut-the-selection call that is a no-op because there is no separate
/// selection state) — it is the ADJACENT property, not this one. Asserting
/// the EDL is untouched by the drag ALONE is what actually discriminates
/// the two implementations.
@MainActor
struct SelectionTests {
    @Test("A drag alone leaves the EDL unchanged, but does register a selection")
    func dragAloneLeavesTheEDLUnchanged() async throws {
        let sourceSeconds = 8.0
        let bundle = try await makeSelectionTestBundle(seconds: sourceSeconds)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: EditDecisionList(), events: [])

        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.onScrub = { [weak state] in state?.onScrub($0) }
        view.onSelect = { [weak state] in state?.onSelect($0) }
        view.update(duration: sourceSeconds, cuts: [], markerPoints: [], playhead: 0)

        // A deliberate drag, comfortably past the pixel threshold: source
        // 2s..6s on an 800px/8s view (x200 -> x600).
        view.mouseDown(with: .synthetic(at: NSPoint(x: 200, y: 20), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: 600, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 600, y: 20), in: view))

        // The separation this task exists to establish: the drag must not
        // have touched the document at all.
        #expect(state.edl.cuts.isEmpty)
        // It must not have been silently swallowed either — a broken
        // threshold or a dropped callback would ALSO leave `edl.cuts`
        // empty, trivially and wrongly satisfying the assertion above.
        // The drag genuinely registering as a selection is what rules
        // that out.
        let selection = try #require(state.selection)
        #expect(abs(selection.range.start - 2.0) < 0.05)
        #expect(abs(selection.range.end - 6.0) < 0.05)
    }

    @Test("Cutting a selection produces exactly one Cut covering it, and clears the selection")
    func cuttingASelectionProducesOneCutAndClearsSelection() async throws {
        let sourceSeconds = 8.0
        let bundle = try await makeSelectionTestBundle(seconds: sourceSeconds)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: EditDecisionList(), events: [])

        let range = TimeRange(start: 2.0, end: 6.0)
        state.onSelect(Selection(range: range))
        // Sanity check on the OTHER half of the separation: selecting alone
        // (exactly what the previous test pins) must not have touched `edl`.
        #expect(state.edl.cuts.isEmpty)

        state.cutSelection()

        #expect(state.edl.cuts.count == 1)
        let cut = try #require(state.edl.cuts.first)
        #expect(cut.range == range)
        // The selection must be gone — once it has become an edit, there is
        // nothing left selected. A wrong implementation that cuts but
        // forgets to clear `selection` would leave the Cut button (in
        // `EditorContentView`) enabled over an edit that already happened.
        #expect(state.selection == nil)

        // Let the resulting autosave finish before the bundle underneath it
        // goes away with the test.
        await state.waitForPendingSave()
    }

    @Test("Cutting with nothing selected is a no-op")
    func cuttingWithNoSelectionIsANoOp() async throws {
        let sourceSeconds = 8.0
        let bundle = try await makeSelectionTestBundle(seconds: sourceSeconds)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: EditDecisionList(), events: [])

        // No `onSelect` call at all — `state.selection` starts `nil`.
        state.cutSelection()

        #expect(state.edl.cuts.isEmpty)
        #expect(state.selection == nil)
    }
}
