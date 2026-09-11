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

/// A selected cut looks selected.
///
/// `FoldSelectionTests` next door asserts the MODEL — that clicking a fold
/// selects it and that Delete then removes it — and it passed throughout the
/// period when a selected cut drew exactly like an unselected one, because
/// every assertion in it stops at `EditorTimelineState`. `selectedFoldID` was
/// never handed to `TimelineView` at all.
///
/// So the test that matters here is `selectionSurvivesTheTripToTheView`: it
/// goes model → `DisplayState` → `update` → what the view would draw, which
/// is the trip that was broken. The palette assertions above it are about the
/// relationship between the four looks; a mutant that made selected and
/// unselected identical passes every one of the model tests.
@Suite(.serialized)
@MainActor
struct FoldAppearanceTests {
    init() { _ = NSApplication.shared }

    private let width = 800.0
    private let duration = 20.0

    private func makeState(cuts: [Cut]) async throws -> EditorTimelineState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: duration)
        let edl = EditDecisionList(cuts: cuts)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        try await controller.apply(edl: edl, events: [])
        return EditorTimelineState(controller: controller, edl: edl, events: [])
    }

    @Test("The four looks are four looks, not two")
    func everyStateIsDistinguishable() {
        // The whole defect in one assertion: for a while, all four of these
        // drew the same. A palette that returned one fill and one width would
        // satisfy any test that only asked "is it red".
        let looks: [FoldPalette.Appearance] = [
            .collapsed, .collapsedSelected, .expanded, .expandedSelected]
        let signatures = looks.map { look in
            "\(FoldPalette.fill(look).alphaComponent)-"
            + "\(FoldPalette.lineWidth(look))-\(FoldPalette.borderWidth(look))"
        }
        #expect(Set(signatures).count == 4, "two fold states are drawn identically")
    }

    @Test("Selected is the same red, only stronger")
    func selectionIsAVariantNotANewColour() {
        // The product-owner's wording: "a highlight color variant of the red
        // transparent unselected color". A selected cut that turned orange
        // would read as a different KIND of thing rather than as this thing,
        // chosen — and would be a third opinion about what a cut looks like,
        // alongside the line and the band.
        // HUE, not identical components. Rev 5 gives a selected collapsed cut
        // `redBright` — a lighter red, and the second channel a three-point
        // line needs once it is the only thing marking selection. That is
        // still "this thing, chosen": same hue, more emphasis. Asserting the
        // components were byte-identical was one implementation of the rule,
        // not the rule, and it would have blocked exactly the change the rule
        // permits while still passing for an orange with the same alpha.
        for look in [FoldPalette.Appearance.collapsed, .collapsedSelected,
                     .expanded, .expandedSelected] {
            let fill = FoldPalette.fill(look).usingColorSpace(.sRGB)!
            #expect(fill.redComponent > fill.greenComponent + 0.3,
                    "\(look) is not red: \(fill)")
            #expect(abs(fill.greenComponent - fill.blueComponent) < 0.02,
                    "\(look) has drifted off the red axis toward orange: \(fill)")
        }
        // Stronger, in the direction that reads as emphasis on each shape:
        // more opaque for the band, wider AND brighter for the line.
        #expect(FoldPalette.fill(.expandedSelected).alphaComponent
                > FoldPalette.fill(.expanded).alphaComponent)
        #expect(FoldPalette.lineWidth(.collapsedSelected)
                > FoldPalette.lineWidth(.collapsed))
        // Brightness is the channel rev 5 added, and width alone no longer
        // covers it: a mutant that put the collapsed-selected fill back to
        // plain `base` kept every other assertion here green, because the
        // line was still wider and still red.
        func luminance(_ color: NSColor) -> Double {
            let c = color.usingColorSpace(.sRGB)!
            return 0.299 * Double(c.redComponent) + 0.587 * Double(c.greenComponent)
                 + 0.114 * Double(c.blueComponent)
        }
        #expect(luminance(FoldPalette.fill(.collapsedSelected))
                > luminance(FoldPalette.fill(.collapsed)) + 0.05,
                "a selected collapsed cut is no brighter than an unselected one")
    }

    @Test("A selected collapsed cut gets a wash, because three points cannot carry it")
    func selectedCollapsedCutGetsAWash() {
        // The channel a collapsed cut gained in rev 5 (W11). It is drawn three
        // points wide across the whole stack; brightening three points is not
        // enough to say "this is what ⌫ deletes". Nothing else has a wash —
        // an expanded cut already has a body — so a wash on any other state
        // would be noise.
        let wash = FoldPalette.selectionWash(.collapsedSelected)
        #expect(wash != nil, "an armed cut has nothing but three brighter points")
        #expect((wash?.alphaComponent ?? 0) > 0.05 && (wash?.alphaComponent ?? 1) < 0.25,
                "the wash is either invisible or loud enough to read as a band of its own")
        for quiet in [FoldPalette.Appearance.collapsed, .expanded, .expandedSelected] {
            #expect(FoldPalette.selectionWash(quiet) == nil, "\(quiet) grew a wash")
        }
    }

    @Test("Only the selected band gets an edge")
    func borderMarksTheSelectedBandAlone() {
        // A border on every band is a border that says nothing.
        #expect(FoldPalette.borderWidth(.expandedSelected) > 0)
        #expect(FoldPalette.borderWidth(.expanded) == 0)
        #expect(FoldPalette.borderWidth(.collapsed) == 0)
        #expect(FoldPalette.borderWidth(.collapsedSelected) == 0)
    }

    @Test("Double-clicking a cut expands it AND selects it, all the way to the view")
    func selectionSurvivesTheTripToTheView() async throws {
        // The trip that was broken, driven end to end. `expandAndSelect` is
        // what a double-click on the fold calls (`GestureMatrixTests` covers
        // the gesture reaching it); this asserts what the timeline would draw
        // once it has.
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let state = try await makeState(cuts: [cut])
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: 160))

        state.expandAndSelect(foldID: cut.id)
        view.apply(state.displayState(playhead: 0))

        #expect(view.foldAppearanceForTesting(cut.id) == .expandedSelected)
    }

    @Test("An unselected cut is not drawn as a selected one")
    func theOtherCutIsNotHighlighted() async throws {
        // Selecting one cut must not light up its neighbour. A view that
        // stored a Bool rather than an id passes the test above and fails
        // this one.
        let first = Cut(range: TimeRange(start: 4, end: 5))
        let second = Cut(range: TimeRange(start: 10, end: 12))
        let state = try await makeState(cuts: [first, second])
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: 160))

        state.expandAndSelect(foldID: second.id)
        view.apply(state.displayState(playhead: 0))

        #expect(view.foldAppearanceForTesting(second.id) == .expandedSelected)
        #expect(view.foldAppearanceForTesting(first.id) == .collapsed)
    }

    @Test("A selected cut collapsed again still reads as selected")
    func collapsingKeepsTheSelectionVisible() async throws {
        // Single-clicking in the fold lane selects AND toggles, so a second
        // click collapses a cut that is still selected — and Delete still
        // removes it. If the collapsed line looked ordinary there, the thing
        // Delete is about to act on would be unmarked.
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let state = try await makeState(cuts: [cut])
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: 160))

        state.selectFold(id: cut.id)
        state.toggleExpansion(of: cut.id)
        state.toggleExpansion(of: cut.id)
        view.apply(state.displayState(playhead: 0))

        #expect(view.foldAppearanceForTesting(cut.id) == .collapsedSelected)
    }

    @Test("Delete removes the cut from both the expanded and the collapsed state")
    func deleteWorksFromEitherState() async throws {
        // Stated as one test because it is one requirement: the highlight is
        // what Delete acts on, and whether the cut happens to be open changes
        // nothing about that.
        for expanded in [true, false] {
            let cut = Cut(range: TimeRange(start: 10, end: 12))
            let state = try await makeState(cuts: [cut])
            if expanded {
                state.expandAndSelect(foldID: cut.id)
            } else {
                state.selectFold(id: cut.id)
            }
            state.deleteSelection()
            #expect(state.edl.cuts.isEmpty,
                    "Delete left the cut in place (expanded: \(expanded))")
        }
    }
}
