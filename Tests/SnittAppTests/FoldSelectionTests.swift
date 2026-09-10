// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// Clicking a fold highlights what it removed, and Delete puts it back.
///
/// A range selection and a selected fold look the same on screen — both are a
/// highlighted span — but Delete means opposite things for them. These assert
/// the distinction is kept rather than guessed.
@Suite(.serialized)
@MainActor
struct FoldSelectionTests {
    private let width = 800.0
    private let duration = 20.0

    /// Built the way every other editor-state test here builds one, rather
    /// than a stub: the dispatch under test reads `edl.cuts`, and a stub that
    /// only pretended to have them would assert nothing about the real path.
    private func makeState(cuts: [Cut]) async throws -> EditorTimelineState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 20)
        let edl = EditDecisionList(cuts: cuts)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        try await controller.apply(edl: edl, events: [])
        return EditorTimelineState(controller: controller, edl: edl, events: [])
    }

    private func makeView() -> (TimelineView, Cut) {
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: 160))
        view.update(duration: duration, cuts: [cut], markerPoints: [], playhead: 0)
        return (view, cut)
    }

    @Test("Right-click reaches a fold anywhere on its line, not just in the fold lane")
    func rightClickIsNotGated() {
        // The regression. The fold's line is drawn full height on purpose, and
        // gating hits to the 24pt fold lane — done to stop ungated LEFT clicks
        // swallowing scrubs — silently removed Remove Cut everywhere else.
        let (view, cut) = makeView()
        let geometry = TimelineGeometry(
            width: width,
            timebase: Timebase(sourceDuration: duration, edl: EditDecisionList(cuts: [cut])))
        let foldX = CGFloat(geometry.x(atFold: cut))
        // View coordinates, not a synthetic event: on a windowless view the
        // event path exercises AppKit's conversion rather than the hit test,
        // and a mutant that re-gated the menu survived a test written that
        // way. Deep in the audio bands, far below the fold lane.
        let menu = view.contextMenu(at: NSPoint(x: foldX, y: 130))
        #expect(menu?.items.first?.title == "Remove Cut")
        // And still nothing where there is no fold at all.
        #expect(view.contextMenu(at: NSPoint(x: 10, y: 130)) == nil)
    }

    @Test("Delete removes a selected fold instead of cutting")
    func deleteRemovesASelectedFold() async throws {
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let state = try await makeState(cuts: [cut])
        state.selectFold(id: cut.id)
        #expect(state.selection != nil, "clicking a fold did not highlight it")
        state.deleteSelection()
        #expect(state.edl.cuts.isEmpty, "Delete did not remove the fold")
    }

    @Test("Delete still cuts an ordinary range selection")
    func deleteStillCutsARange() async throws {
        // The other half. A dispatch that always removed folds would break the
        // gesture this key has had since D56.
        let state = try await makeState(cuts: [])
        state.onSelect(Selection(range: TimeRange(start: 2, end: 4)))
        state.deleteSelection()
        #expect(state.edl.cuts.count == 1, "Delete did not cut the selected range")
    }

    @Test("Selecting a range clears a previously selected fold")
    func rangeSelectionClearsTheFold() async throws {
        // Without this, dragging a new range after clicking a fold leaves
        // Delete still meaning "remove that cut" while the highlight shows
        // something else — the key would edit a span the user is not looking
        // at.
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let state = try await makeState(cuts: [cut])
        state.selectFold(id: cut.id)
        state.onSelect(Selection(range: TimeRange(start: 2, end: 4)))
        state.deleteSelection()
        #expect(state.edl.cuts.count == 2, "Delete removed a fold the user was not looking at")
    }
}
