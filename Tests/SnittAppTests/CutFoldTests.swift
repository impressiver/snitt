// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import AVFoundation
@testable import SnittApp
import SnittDocument
import SnittExport
import Testing

/// D56 (M5f Task 5): a cut collapses to a red line with its two edges
/// touching — a FOLD, not a gap and not the red overlay patch Task 3
/// deleted. Clicking it expands it in place on transparent red, showing the
/// folded segment; right-clicking offers Remove Cut, which restores the
/// segment.
///
/// Three traps this file exists to catch, each with its own tests below:
///
/// 1. Expansion is a VIEW state. `expandingAFoldLeavesOutputDurationUnchanged`
///    and `playbackStillSkipsAnExpandedCut` assert against `Timebase`/the
///    real composition — never against anything drawn — because "a wider
///    rectangle appeared" is the ADJACENT property to "the model didn't
///    move," and this project has repeatedly shipped exactly that
///    adjacent-property mistake (M5f Task 5 dispatch names twenty-six of
///    them).
/// 2. A fold is a thin target. `CutFoldTimelineViewTests` pins that a click
///    ON the fold toggles expansion and a click ELSEWHERE still scrubs even
///    with a fold nearby — the same drag-vs-cut ambiguity Task 4 solved one
///    interaction earlier.
/// 3. Removing a cut is a real edit: undoable, and it persists.
///    `removingACutIsUndoable` and `CutRemovalPersistenceTests` (which goes
///    all the way through closing and reopening the document) pin that.
///
/// Pure fold-position arithmetic (`Timebase.foldPosition(for:)`,
/// `TimelineGeometry.x(atFold:)`) is pinned in `TimebaseTests.swift` /
/// `TimelineGeometryTests.swift` instead — this file drives the real
/// `EditorTimelineState`/`TimelineView` wiring on top of it, not a
/// reimplementation of the arithmetic.

/// A tiny bundle with a real, loadable `capture.mov`. Duplicated rather than
/// shared with `SelectionTests.swift`/`EditorTimelineStateTests.swift`'s
/// identical-in-spirit helpers: Swift Testing target sources don't share
/// PRIVATE helpers across files (see those files' own doc comments), so this
/// file gets its own thin wrapper around the target-shared
/// `writeSyntheticMovie` (`SyntheticMovie.swift`, not `private`, so it IS
/// visible here).
@MainActor
private func makeCutFoldTestBundle(seconds: Double) async throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds)
    return bundle
}

/// Polls `controller.durationSeconds` (the TRIMMED/output duration) until it
/// lands near `target` or `timeout` elapses. Duplicated from
/// `EditorTimelineStateTests.swift` per that file's own note on private
/// helpers not sharing across files.
@MainActor
private func waitForDuration(_ controller: PreviewController, toApproach target: Double,
                              timeout: Double = 5.0) async {
    var waited = 0.0
    while abs(controller.durationSeconds - target) > 0.2, waited < timeout {
        try? await Task.sleep(nanoseconds: 20_000_000)
        waited += 0.02
    }
}

// MARK: - Model isolation, playback, undo (Traps 1 and 3)

@MainActor
struct CutFoldTests {
    @Test("Expanding a fold leaves output duration unchanged")
    func expandingAFoldLeavesOutputDurationUnchanged() async throws {
        let sourceSeconds = 8.0
        let bundle = try await makeCutFoldTestBundle(seconds: sourceSeconds)
        let built = try await CompositionBuilder.build(bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: EditDecisionList(), events: [])

        state.onSelect(Selection(range: TimeRange(start: 2, end: 4)))
        state.cutSelection()
        await waitForDuration(controller, toApproach: sourceSeconds - 2.0)
        let durationBeforeExpansion = controller.durationSeconds
        #expect(abs(durationBeforeExpansion - 6.0) < 0.2)

        let cutID = try #require(state.edl.cuts.first?.id)
        state.toggleExpansion(of: cutID)

        // A plausible wrong implementation treats "expand" as a temporary
        // un-cut — restoring the segment so there is something to show, and
        // re-cutting it on collapse. That would enqueue a real compositor
        // rebuild and grow `durationSeconds` back toward 8.0; give any such
        // (wrongly) enqueued save every chance to land before asserting it
        // did not happen.
        await state.waitForPendingSave()
        #expect(controller.durationSeconds == durationBeforeExpansion)
        #expect(state.edl.cuts.count == 1)
        #expect(state.edl.cuts.first?.id == cutID)

        // The property named directly, against `Timebase` itself rather
        // than the player's cached copy of it.
        let timebase = Timebase(sourceDuration: sourceSeconds, edl: state.edl)
        #expect(timebase.outputDuration == 6.0)
    }

    @Test("Playback still skips an expanded cut's span")
    func playbackStillSkipsAnExpandedCut() async throws {
        let sourceSeconds = 8.0
        let bundle = try await makeCutFoldTestBundle(seconds: sourceSeconds)
        let built = try await CompositionBuilder.build(bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: EditDecisionList(), events: [])

        // Cut source 2-4s.
        state.onSelect(Selection(range: TimeRange(start: 2, end: 4)))
        state.cutSelection()
        await waitForDuration(controller, toApproach: sourceSeconds - 2.0)

        let cutID = try #require(state.edl.cuts.first?.id)
        state.toggleExpansion(of: cutID)
        await controller.seek(toSeconds: 0)

        // Source 3.0s is squarely inside the removed 2-4s region. Expanded
        // or not, `onScrub` must still SEEK (snapping to the nearest kept
        // edge) rather than land somewhere inside footage the COMPOSITION
        // never contains — asserted against the player's actual current
        // time, i.e. the composition itself, never against anything drawn.
        state.onScrub(3.0)

        var waited = 0.0
        while CMTimeGetSeconds(controller.player.currentTime()) < 1.9, waited < 5.0 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            waited += 0.02
        }
        #expect(abs(CMTimeGetSeconds(controller.player.currentTime()) - 2.0) < 0.3)
    }

    @Test("Toggling a fold's expansion twice returns it to collapsed, and never touches edl")
    func togglingExpansionTwiceReturnsToCollapsed() async throws {
        let sourceSeconds = 8.0
        let bundle = try await makeCutFoldTestBundle(seconds: sourceSeconds)
        let built = try await CompositionBuilder.build(bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: EditDecisionList(), events: [])

        state.onSelect(Selection(range: TimeRange(start: 2, end: 4)))
        state.cutSelection()
        await state.waitForPendingSave()
        let cutID = try #require(state.edl.cuts.first?.id)

        state.toggleExpansion(of: cutID)
        #expect(state.expandedCutIDs.contains(cutID))
        state.toggleExpansion(of: cutID)
        #expect(!state.expandedCutIDs.contains(cutID))
        #expect(state.edl.cuts.count == 1)
    }

    @Test("Removing a cut restores the segment: duration grows by its length, and the EDL loses exactly that Cut by id")
    func removingACutRestoresTheSegment() async throws {
        let sourceSeconds = 8.0
        let bundle = try await makeCutFoldTestBundle(seconds: sourceSeconds)
        let built = try await CompositionBuilder.build(bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: EditDecisionList(), events: [])

        // Two DISTINCT cuts, so removing one provably leaves the other
        // intact — asserting only "count went from 2 to 1" would also pass
        // a wrong implementation that clears the WHOLE edl instead of
        // removing one Cut by id.
        state.onSelect(Selection(range: TimeRange(start: 1, end: 2)))
        state.cutSelection()
        await state.waitForPendingSave()
        state.onSelect(Selection(range: TimeRange(start: 5, end: 6)))
        state.cutSelection()
        await waitForDuration(controller, toApproach: sourceSeconds - 2.0)
        #expect(state.edl.cuts.count == 2)

        let keptCut = try #require(state.edl.cuts.first)
        let removedCut = try #require(state.edl.cuts.last)
        #expect(keptCut.id != removedCut.id)
        let durationBeforeRemoval = controller.durationSeconds

        state.removeCut(id: removedCut.id)
        await waitForDuration(controller, toApproach: durationBeforeRemoval + (removedCut.range.end - removedCut.range.start))

        #expect(state.edl.cuts.count == 1)
        #expect(state.edl.cuts.first?.id == keptCut.id)
        #expect(!state.edl.cuts.contains { $0.id == removedCut.id })

        let expectedDuration = durationBeforeRemoval + (removedCut.range.end - removedCut.range.start)
        #expect(abs(controller.durationSeconds - expectedDuration) < 0.2)
    }

    @Test("Removing a cut is undoable through the same UndoManager")
    func removingACutIsUndoable() async throws {
        let sourceSeconds = 8.0
        let bundle = try await makeCutFoldTestBundle(seconds: sourceSeconds)
        let built = try await CompositionBuilder.build(bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: EditDecisionList(), events: [])
        let manager = UndoManager()
        state.undoManager = manager

        state.onSelect(Selection(range: TimeRange(start: 2, end: 4)))
        state.cutSelection()
        await state.waitForPendingSave()
        let cutID = try #require(state.edl.cuts.first?.id)

        state.removeCut(id: cutID)
        await state.waitForPendingSave()
        #expect(state.edl.cuts.isEmpty)

        manager.undo()
        await state.waitForPendingSave()

        #expect(state.edl.cuts.count == 1)
        #expect(state.edl.cuts.first?.id == cutID)
    }

    /// The Edit ▸ Cut Selection menu item's enablement (Task 5, D56) is
    /// gated on this property, but the menu-level path itself resolves
    /// through `NSApp.keyWindow` (see `AppShellTests`'s doc comment on why
    /// that half is not exercised end-to-end in this test host). This
    /// covers the property the guard actually depends on directly, with no
    /// window needing to be key or even shown at all — `EditorWindowController`
    /// is constructed but `.show()` is deliberately never called, matching
    /// `EditorPersistenceTests.laterTrimIsNotOverwrittenByAnEarlierSave`'s
    /// own pattern for the same reason.
    @Test("hasTimelineSelection reflects whatever the timeline last selected")
    func hasTimelineSelectionReflectsSelection() async throws {
        let bundle = try await makeCutFoldTestBundle(seconds: 8)
        let built = try await CompositionBuilder.build(bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        let editor = EditorWindowController(controller: controller, title: "cut-fold-test",
                                            bundleURL: bundle.url, edl: EditDecisionList(), events: [])

        #expect(editor.hasTimelineSelection == false)
        editor.selectForTesting(TimeRange(start: 1, end: 3))
        #expect(editor.hasTimelineSelection == true)
    }

    @Test("Removing a cut id that no longer exists is a no-op")
    func removingAnUnknownCutIsANoOp() async throws {
        let sourceSeconds = 8.0
        let bundle = try await makeCutFoldTestBundle(seconds: sourceSeconds)
        let built = try await CompositionBuilder.build(bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: EditDecisionList(), events: [])

        state.onSelect(Selection(range: TimeRange(start: 2, end: 4)))
        state.cutSelection()
        await state.waitForPendingSave()
        #expect(state.edl.cuts.count == 1)

        state.removeCut(id: UUID())
        #expect(state.edl.cuts.count == 1)
    }
}

// MARK: - Fold hit-testing (Trap 2)

@MainActor
struct CutFoldTimelineViewTests {
    @Test("A click on a fold toggles its expansion instead of scrubbing")
    func clickOnAFoldTogglesExpansionInsteadOfScrubbing() {
        let width = 800.0
        let duration = 20.0
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let geometry = TimelineGeometry(
            width: width, timebase: Timebase(sourceDuration: duration, edl: EditDecisionList(cuts: [cut])))
        let foldX = CGFloat(geometry.x(atFold: cut))

        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        view.update(duration: duration, cuts: [cut], markerPoints: [], playhead: 0)
        var scrubbed: Double?
        var expanded: UUID?
        view.onScrub = { scrubbed = $0 }
        view.onExpandAndSelectFold = { expanded = $0 }

        // DOUBLE-click: rev 5 (W11) gives a single click to the lane under
        // the pointer, because cuts are drawn full height and an ungated
        // single-click hit took scrubs away from every lane. The gesture
        // changed; what this test is about did not.
        view.mouseDown(with: .synthetic(at: NSPoint(x: foldX, y: 20), in: view, clickCount: 2))

        #expect(expanded == cut.id)
        // The whole point of the hit-test: a fold click must not ALSO
        // scrub — a wrong implementation that checks `foldHit` but still
        // falls through to the scrub path afterward would fire both.
        #expect(scrubbed == nil)
    }

    @Test("A click elsewhere on the track still scrubs while a fold is nearby")
    func clickElsewhereOnTheTrackStillScrubsWhileAFoldIsNearby() {
        // Task 5 dispatch, Trap 2, verbatim: without a deliberate hit-test,
        // `mouseDown`'s pre-existing scrub logic runs for EVERY mouse-down
        // on the track — this is the case that catches a reversion to that.
        let width = 800.0
        let duration = 20.0
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        view.update(duration: duration, cuts: [cut], markerPoints: [], playhead: 0)
        var scrubbed: Double?
        var toggled: UUID?
        view.onScrub = { scrubbed = $0 }
        view.onToggleExpansion = { toggled = $0 }

        // x=100 is nowhere near this cut's fold (which sits well past the
        // middle of the view). The view shows 18s of OUTPUT across 800px
        // with [10,12] removed, so x=100 is output 2.25 — and source 2.25,
        // since nothing before it has been cut.
        //
        // This number was 2.5 until the M5f whole-branch review: gestures
        // were interpreted on a fixed 20s SOURCE scale while every pixel
        // was drawn on the 18s output one, so a click resolved to an
        // instant 100px from where it landed. 2.5 pinned that, not this.
        view.mouseDown(with: .synthetic(at: NSPoint(x: 100, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: 100, y: 20), in: view))

        #expect(toggled == nil)
        #expect(abs((scrubbed ?? -1) - 2.25) < 0.01)
    }

    @Test("A click just past the fold's hit margin scrubs rather than toggling")
    func clickJustOutsideFoldMarginScrubs() {
        let width = 800.0
        let duration = 20.0
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let geometry = TimelineGeometry(
            width: width, timebase: Timebase(sourceDuration: duration, edl: EditDecisionList(cuts: [cut])))
        let foldX = geometry.x(atFold: cut)

        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        view.update(duration: duration, cuts: [cut], markerPoints: [], playhead: 0)
        var scrubbed: Double?
        var toggled: UUID?
        view.onScrub = { scrubbed = $0 }
        view.onToggleExpansion = { toggled = $0 }

        // 12px past the fold clears any reasonable hit margin without
        // landing so far away that a generous margin would coincidentally
        // also miss it.
        let x = CGFloat(foldX + 12)
        view.mouseDown(with: .synthetic(at: NSPoint(x: x, y: 20), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: x, y: 20), in: view))

        #expect(toggled == nil)
        #expect(scrubbed != nil)
    }

    @Test("Clicking within an expanded fold's widened rect collapses it back")
    func clickInsideExpandedFoldCollapses() {
        let width = 800.0
        let duration = 20.0
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        // Built WITH the expansion, like the view's own geometry — an expanded
        // fold inserts its source length into the axis, so both the scale and
        // the band's position differ from the collapsed case.
        //
        // This test used to compute the click point as `x(atFold:) + width/2`.
        // That was correct only while expansion did not reflow: `x(atFold:)`
        // is the instant the cut collapsed TO, which after insertion is the
        // band's trailing edge, so the old formula pointed a full half-width
        // past the visible rectangle.
        let timebase = Timebase(sourceDuration: duration, edl: EditDecisionList(cuts: [cut]))
        let geometry = TimelineGeometry(
            width: width, timebase: timebase,
            expansions: [.init(output: timebase.foldPosition(for: cut),
                               seconds: cut.range.end - cut.range.start)])
        let span = geometry.expansionSpan(atOutput: timebase.foldPosition(for: cut))!
        let midpoint = CGFloat(span.x + span.width / 2)

        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        view.update(duration: duration, cuts: [cut], markerPoints: [], playhead: 0,
                   expandedCutIDs: [cut.id])
        var expanded: UUID?
        view.onExpandAndSelectFold = { expanded = $0 }

        // DOUBLE-click: rev 5 (W11) gives a single click to the lane under
        // the pointer, because cuts are drawn full height and an ungated
        // single-click hit took scrubs away from every lane. The gesture
        // changed; what this test is about did not.
        view.mouseDown(with: .synthetic(at: NSPoint(x: midpoint, y: 20), in: view, clickCount: 2))

        #expect(expanded == cut.id)
    }

    @Test("Right-clicking a fold offers Remove Cut")
    func rightClickOnAFoldOffersRemoveCut() throws {
        let width = 800.0
        let duration = 20.0
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let geometry = TimelineGeometry(
            width: width, timebase: Timebase(sourceDuration: duration, edl: EditDecisionList(cuts: [cut])))
        let foldX = CGFloat(geometry.x(atFold: cut))

        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        view.update(duration: duration, cuts: [cut], markerPoints: [], playhead: 0)

        let menu = view.menu(for: .synthetic(at: NSPoint(x: foldX, y: 20), in: view))
        let item = try #require(menu?.items.first, "no context menu near the fold")
        #expect(item.title == "Remove Cut")
        #expect(item.representedObject as? UUID == cut.id)
    }

    @Test("Right-clicking elsewhere on the track offers no menu")
    func rightClickElsewhereOffersNoMenu() {
        let width = 800.0
        let duration = 20.0
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        view.update(duration: duration, cuts: [cut], markerPoints: [], playhead: 0)

        let menu = view.menu(for: .synthetic(at: NSPoint(x: 100, y: 20), in: view))
        #expect(menu == nil)
    }

    @Test("Choosing Remove Cut fires onRemoveCut with the cut's id")
    func choosingRemoveCutFiresOnRemoveCutWithTheCutsID() {
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.update(duration: 20, cuts: [cut], markerPoints: [], playhead: 0)
        var removed: UUID?
        view.onRemoveCut = { removed = $0 }

        // Exactly the `NSMenuItem` `menu(for:)` would have built.
        let item = NSMenuItem(title: "Remove Cut", action: nil, keyEquivalent: "")
        item.representedObject = cut.id
        view.handleRemoveCutMenuItem(item)

        #expect(removed == cut.id)
    }
}

// MARK: - Persistence across close/reopen (Trap 3, "verify by reopening")

/// `.serialized` and touching `NSApplication.shared` once before any test
/// body runs, for the same reasons `EditorPersistenceTests` does: this
/// suite opens real, real-EDL `EditorWindowController`s via
/// `DocumentOpener.open`, which shows a real front-ordered `NSWindow`, and
/// every body runs inside `EditorWindowTestGate` so that doesn't collide
/// with another concurrently-running gated suite's own window bookkeeping.
@Suite(.serialized)
@MainActor
struct CutRemovalPersistenceTests {
    init() { _ = NSApplication.shared }

    private func makeFixtureBundle() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cutfold-fixture-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 12)
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)
        try EventLog(events: []).write(to: bundle)
        try EditDecisionList.fullRange().write(to: bundle)
        return url
    }

    @Test("Removing a cut persists, and the removal survives reopening the document")
    func removalPersistsAndSurvivesReopen() async throws {
        let url = try await makeFixtureBundle()
        defer { try? FileManager.default.removeItem(at: url) }

        try await EditorWindowTestGate.run {
            let first = try await DocumentOpener.open(bundleURL: url)
            first.applyTrimForTesting(TimeRange(start: 1.0, end: 3.0))
            await first.waitForPendingSaveForTesting()
            let cutID = try #require(first.currentEDLForTesting().cuts.first?.id)

            first.removeCutForTesting(id: cutID)
            await first.waitForPendingSaveForTesting()
            #expect(first.currentEDLForTesting().cuts.isEmpty)
            first.close()

            // The property Trap 3 actually names: not just "the in-memory
            // EDL says empty" (the adjacent property `EditorPersistenceTests`
            // already warns about) but that CLOSING AND REOPENING the
            // document shows the removal too.
            let second = try await DocumentOpener.open(bundleURL: url)
            defer { second.close() }
            #expect(second.currentEDLForTesting().cuts.isEmpty)

            let reloaded = try EditDecisionList.read(from: SnittBundle(opening: url))
            #expect(reloaded.cuts.isEmpty)
        }
    }

    @Test("Undo after removing a cut persists the cut's return, and it survives reopening")
    func undoOfRemovalPersistsAndSurvivesReopen() async throws {
        let url = try await makeFixtureBundle()
        defer { try? FileManager.default.removeItem(at: url) }

        try await EditorWindowTestGate.run {
            let first = try await DocumentOpener.open(bundleURL: url)
            defer { first.close() }
            first.applyTrimForTesting(TimeRange(start: 1.0, end: 3.0))
            await first.waitForPendingSaveForTesting()
            let cutID = try #require(first.currentEDLForTesting().cuts.first?.id)

            first.removeCutForTesting(id: cutID)
            await first.waitForPendingSaveForTesting()

            first.undoManager?.undo()
            await first.waitForPendingSaveForTesting()
            #expect(first.currentEDLForTesting().cuts.count == 1)

            let reloaded = try EditDecisionList.read(from: SnittBundle(opening: url))
            #expect(reloaded.cuts.count == 1)
            #expect(reloaded.cuts.first?.id == cutID)
        }
    }
}
