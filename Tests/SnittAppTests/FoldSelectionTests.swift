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
    // MARK: - Selecting a cut LINE, so Delete can remove one

    @Test("Right-clicking a cut selects it, without expanding it")
    func rightClickSelectsTheCutLine() async throws {
        // The gap this closes. `FoldPalette` has drawn a `collapsedSelected`
        // appearance since M5f and `deleteSelection` has removed a selected fold
        // for just as long — but `onSelectFold` was declared, wired to the state,
        // and called by NO gesture. A cut line could not be selected at all, so
        // Delete could never remove one: the only way in was a double-click, which
        // expands the fold first.
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let state = try await makeState(cuts: [cut])
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 140))
        view.onSelectFold = { state.selectFold(id: $0) }
        view.update(duration: 20, cuts: [cut], markerPoints: [], playhead: 0)

        let geometry = TimelineGeometry(
            width: 800,
            timebase: Timebase(sourceDuration: 20, edl: EditDecisionList(cuts: [cut])))
        _ = view.contextMenu(at: NSPoint(x: CGFloat(geometry.x(atFold: cut)), y: 70))

        #expect(state.selectedFoldID == cut.id, "right-clicking the cut did not select it")
        #expect(state.selection != nil, "nothing was highlighted, so Delete stays disabled")
        // Collapsed, deliberately: expanding on right-click would move the
        // timeline under the menu that is about to appear.
        #expect(!state.expandedCutIDs.contains(cut.id),
                "right-click expanded the fold; only double-click should do that")
    }

    @Test("Delete then removes the cut line that was right-clicked")
    func deleteRemovesARightClickedCutLine() async throws {
        // The end the request names: select a cut line, hit Delete, it is gone.
        // Driven through the same seam a right-click uses rather than by calling
        // `selectFold` directly — the model half was already tested and already
        // worked; the gesture was the missing piece.
        let cut = Cut(range: TimeRange(start: 4, end: 6))
        let state = try await makeState(cuts: [cut])
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 140))
        view.onSelectFold = { state.selectFold(id: $0) }
        view.update(duration: 20, cuts: [cut], markerPoints: [], playhead: 0)

        let geometry = TimelineGeometry(
            width: 800,
            timebase: Timebase(sourceDuration: 20, edl: EditDecisionList(cuts: [cut])))
        _ = view.contextMenu(at: NSPoint(x: CGFloat(geometry.x(atFold: cut)), y: 70))
        state.deleteSelection()

        #expect(state.edl.cuts.isEmpty, "Delete did not remove the selected cut line")
    }

    @Test("A selected cut line draws as selected, collapsed")
    func collapsedSelectedIsReachable() {
        // `collapsedSelected` existed and nothing could produce it — the appearance
        // was designed, drawn, and unreachable. Asserted against the palette rather
        // than the pixels, which the headless host cannot see.
        #expect(FoldPalette.appearance(expanded: false, selected: true) == .collapsedSelected)
        #expect(FoldPalette.appearance(expanded: false, selected: false) == .collapsed)
        #expect(FoldPalette.appearance(expanded: true, selected: true) == .expandedSelected)
    }

    @Test("Right-clicking away from a cut selects nothing")
    func rightClickOffACutSelectsNothing() async throws {
        // Selecting on any right-click would clear a range the user had just
        // dragged, which is a silent edit to what Delete will do next.
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let state = try await makeState(cuts: [cut])
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 140))
        view.onSelectFold = { state.selectFold(id: $0) }
        view.update(duration: 20, cuts: [cut], markerPoints: [], playhead: 0)

        #expect(view.contextMenu(at: NSPoint(x: 5, y: 70)) == nil)
        #expect(state.selectedFoldID == nil, "a right-click off the cut selected it anyway")
    }

    @Test("A double-clicked fold stays selected after the mouse comes back up")
    func doubleClickSelectionSurvivesMouseUp() async throws {
        // The defect this file's other tests could not see. A double-click
        // delivers mouseDown(1), mouseUp, mouseDown(2), mouseUp — and the
        // TRAILING mouseUp used to fall through to the plain-click path,
        // calling `onSelect(nil)` and clearing the selection `mouseDown` had
        // just made. On screen the fold highlighted and deselected instantly,
        // so an expanded fold could not be selected at all.
        //
        // Every existing double-click test drove `mouseDown` and stopped, so
        // each asserted the selection that IS made and none the one that was
        // immediately taken away. Driving the WHOLE gesture is the difference.
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let state = try await makeState(cuts: [cut])
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 140))
        view.onExpandAndSelectFold = { state.expandAndSelect(foldID: $0) }
        view.onSelect = { state.onSelect($0) }
        view.update(duration: 20, cuts: [cut], markerPoints: [], playhead: 0)

        let geometry = TimelineGeometry(
            width: 800,
            timebase: Timebase(sourceDuration: 20, edl: EditDecisionList(cuts: [cut])))
        let at = NSPoint(x: CGFloat(geometry.x(atFold: cut)), y: 70)
        view.mouseDown(with: .synthetic(at: at, in: view, clickCount: 2))
        #expect(state.selectedFoldID == cut.id, "the double-click did not select at all")
        view.mouseUp(with: .synthetic(at: at, in: view, clickCount: 2))

        #expect(state.selectedFoldID == cut.id,
                "mouseUp cleared the selection the double-click had just made")
        #expect(state.expandedCutIDs.contains(cut.id), "the fold did not stay expanded")
    }

    @Test("Delete removes a fold selected by double-clicking it")
    func deleteRemovesADoubleClickedFold() async throws {
        // The end the request names, through the whole gesture rather than
        // through `selectFold`: double-click an expanded fold, hit Delete, it
        // is gone. This failed before the fix — not because Delete was wrong,
        // but because nothing was selected by the time Delete ran.
        let cut = Cut(range: TimeRange(start: 4, end: 6))
        let state = try await makeState(cuts: [cut])
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 140))
        view.onExpandAndSelectFold = { state.expandAndSelect(foldID: $0) }
        view.onSelect = { state.onSelect($0) }
        view.update(duration: 20, cuts: [cut], markerPoints: [], playhead: 0)

        let geometry = TimelineGeometry(
            width: 800,
            timebase: Timebase(sourceDuration: 20, edl: EditDecisionList(cuts: [cut])))
        let at = NSPoint(x: CGFloat(geometry.x(atFold: cut)), y: 70)
        view.mouseDown(with: .synthetic(at: at, in: view, clickCount: 2))
        view.mouseUp(with: .synthetic(at: at, in: view, clickCount: 2))
        state.deleteSelection()

        #expect(state.edl.cuts.isEmpty, "Delete did not remove the double-clicked fold")
    }

    @Test("An ordinary click still clears a selection on mouse up")
    func plainClickStillClearsSelection() async throws {
        // The other side of the guard. Claiming the gesture for every press
        // would stop a plain click clearing a previous selection, which is
        // the behaviour clicks have had since before D56.
        let state = try await makeState(cuts: [])
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 140))
        view.onSelect = { state.onSelect($0) }
        view.update(duration: 20, cuts: [], markerPoints: [], playhead: 0)
        state.onSelect(Selection(range: TimeRange(start: 2, end: 4)))

        let at = NSPoint(x: 400, y: 70)
        view.mouseDown(with: .synthetic(at: at, in: view))
        view.mouseUp(with: .synthetic(at: at, in: view))
        #expect(state.selection == nil, "a plain click no longer clears the selection")
    }

}
