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

/// D50/D56 (M5f Task 6): three stacked tracks — a thin marker lane above
/// video, which sits above audio — with markers now MOVEABLE (drag, mapped
/// back to source time for storage) and EDITABLE (label plus the transcript
/// D50 defines).
///
/// Video and audio rendering as separate tracks, with cuts synchronised
/// across them by default, needs no new machinery here: `EditDecisionList`
/// has always had exactly one `cuts` list (no per-track field — D59 cut
/// per-track cuts from this milestone entirely), and `CompositionBuilder`
/// has always built ONE composition from it. `TimelineView.draw` splits its
/// background into three bands purely for appearance (see that method's own
/// "deliberately untested" note); what actually needed new tests is the
/// marker track's INTERACTION, pinned below.
///
/// The trap that matters most (dispatch, verbatim): a marker that moves on
/// screen and not in the document is the M4b defect wearing a different hat.
/// `movingAMarkerStoresSourceTimeNotOutputTime` is the test written
/// specifically against that — it asserts the STORED (source-time) value,
/// never an x position.

// MARK: - TimelineView hit-testing and gesture wiring

@MainActor
struct TrackLayoutTimelineViewTests {
    /// `NSEvent.synthetic(at:in:)` builds an event whose `locationInWindow`
    /// this test names directly — but `TimelineView.isFlipped == true`
    /// (drawing top-down) while `NSEvent` locations are WINDOW coordinates
    /// (bottom-up), and `mouseDown`'s own `convert(_:from:)` flips between
    /// the two even with no real window attached (confirmed empirically:
    /// `view.convert(NSPoint(x: 0, y: 5), from: nil)` on a flipped, unhosted
    /// view of height 56 returns y = 51, not 5). Every existing test in this
    /// target (`TimelineViewTests`, `CutFoldTests`) is x-only and never had
    /// to care; the marker lane is the first thing in this view whose hit
    /// test depends on an exact y, so this helper makes the flip a single,
    /// named place rather than a silent off-by-`height` in every call site.
    /// Pass the y you want `TimelineView` to actually SEE post-conversion;
    /// this returns the raw window-space y that produces it.
    private func windowY(forViewY viewY: Double, height: Double) -> CGFloat {
        CGFloat(height - viewY)
    }

    @Test("A click on a marker in its lane fires onEditMarker, not onScrub or onSelect")
    func clickOnMarkerFiresOnEditMarker() {
        let width = 800.0
        let height = 56.0
        let duration = 20.0
        let marker = JumpPoint(timeSeconds: 10.0, label: "here")
        let geometry = TimelineGeometry(
            width: width, timebase: Timebase(sourceDuration: duration, edl: EditDecisionList()))
        let markerX = CGFloat(geometry.x(atOutput: OutputTime(10.0)))
        // Comfortably inside the marker lane (capped at 14px on this
        // 56px-tall view).
        let y = windowY(forViewY: 5, height: height)

        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.update(duration: duration, cuts: [], markerPoints: [marker], playhead: 0)
        var scrubbed: Double?
        var selected: Selection?
        var edited: UUID?
        var moved: (UUID, Double)?
        view.onScrub = { scrubbed = $0 }
        view.onSelect = { selected = $0 }
        view.onEditMarker = { edited = $0 }
        view.onMoveMarker = { moved = ($0, $1) }

        // Press and release at the same point — no drag.
        view.mouseDown(with: .synthetic(at: NSPoint(x: markerX, y: y), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: markerX, y: y), in: view))

        #expect(edited == marker.id)
        // The whole point of the hit-test: a marker click must not ALSO
        // scrub or select — a wrong implementation that checks `markerHit`
        // but still falls through to the scrub/select path afterward would
        // fire one of these too (mirrors `CutFoldTimelineViewTests`'s fold
        // analogue).
        #expect(scrubbed == nil)
        #expect(selected == nil)
        #expect(moved == nil)
    }

    @Test("A drag on a marker past the pixel threshold fires onMoveMarker with the dropped OUTPUT time")
    func dragOnMarkerFiresOnMoveMarker() throws {
        let width = 800.0
        let height = 56.0
        let duration = 20.0
        let marker = JumpPoint(timeSeconds: 10.0, label: "here")
        let geometry = TimelineGeometry(
            width: width, timebase: Timebase(sourceDuration: duration, edl: EditDecisionList()))
        let markerX = CGFloat(geometry.x(atOutput: OutputTime(10.0)))
        let y = windowY(forViewY: 5, height: height)

        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.update(duration: duration, cuts: [], markerPoints: [marker], playhead: 0)
        var edited: UUID?
        var moved: (id: UUID, outputTime: Double)?
        view.onEditMarker = { edited = $0 }
        view.onMoveMarker = { moved = ($0, $1) }

        view.mouseDown(with: .synthetic(at: NSPoint(x: markerX, y: y), in: view))
        view.mouseDragged(with: .synthetic(at: NSPoint(x: markerX + 100, y: y), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: markerX + 100, y: y), in: view))

        let result = try #require(moved)
        #expect(result.id == marker.id)
        // +100px on an 800px/20s view is +2.5s from the original 10s.
        #expect(abs(result.outputTime - 12.5) < 0.05)
        // A resolved drag must not ALSO fire the click/edit path.
        #expect(edited == nil)
    }

    @Test("A click on the track below still scrubs even with a marker directly above it")
    func clickBelowMarkerLaneStillScrubs() {
        let width = 800.0
        let height = 56.0
        let duration = 20.0
        let marker = JumpPoint(timeSeconds: 10.0, label: "here")
        let geometry = TimelineGeometry(
            width: width, timebase: Timebase(sourceDuration: duration, edl: EditDecisionList()))
        let markerX = CGFloat(geometry.x(atOutput: OutputTime(10.0)))
        // Well below the marker lane (capped at 14px on this 56px view) —
        // squarely in the video/audio tracks, at the SAME x a marker sits
        // above. Task 5's Trap 2 for folds, one track over: a marker
        // hit-test with no y-gate would swallow this click too.
        let y = windowY(forViewY: 30, height: height)

        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.update(duration: duration, cuts: [], markerPoints: [marker], playhead: 0)
        var scrubbed: Double?
        var edited: UUID?
        view.onScrub = { scrubbed = $0 }
        view.onEditMarker = { edited = $0 }

        view.mouseDown(with: .synthetic(at: NSPoint(x: markerX, y: y), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: markerX, y: y), in: view))

        #expect(edited == nil)
        #expect(abs((scrubbed ?? -1) - 10.0) < 0.05)
    }

    @Test("A click just past a marker's hit margin scrubs rather than editing")
    func clickJustOutsideMarkerMarginScrubs() {
        let width = 800.0
        let height = 56.0
        let duration = 20.0
        let marker = JumpPoint(timeSeconds: 10.0, label: "here")
        let geometry = TimelineGeometry(
            width: width, timebase: Timebase(sourceDuration: duration, edl: EditDecisionList()))
        let markerX = geometry.x(atOutput: OutputTime(10.0))
        let y = windowY(forViewY: 5, height: height)

        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.update(duration: duration, cuts: [], markerPoints: [marker], playhead: 0)
        var scrubbed: Double?
        var edited: UUID?
        view.onScrub = { scrubbed = $0 }
        view.onEditMarker = { edited = $0 }

        // 12px past the marker clears any reasonable hit margin without
        // landing so far away a generous margin would coincidentally miss
        // it too.
        let x = CGFloat(markerX + 12)
        view.mouseDown(with: .synthetic(at: NSPoint(x: x, y: y), in: view))
        view.mouseUp(with: .synthetic(at: NSPoint(x: x, y: y), in: view))

        #expect(edited == nil)
        #expect(scrubbed != nil)
    }
}

// MARK: - Marker drag/edit: stored value, undo, persistence

/// Duplicated small helpers rather than shared: Swift Testing target
/// sources don't share PRIVATE helpers across files (see
/// `EditorTimelineStateTests.swift`'s own note on this).
@MainActor
private func makeTrackLayoutTestBundle(seconds: Double) async throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds)
    return bundle
}

@MainActor
struct MarkerEditingStateTests {
    /// THE trap the dispatch names, verbatim: "assert a marker's stored time
    /// after a drag, not its x position." A 2s head cut is what makes
    /// SOURCE and OUTPUT time actually differ here — without one, a bug
    /// that stored the raw output value directly would pass by accident.
    @Test("Moving a marker converts its OUTPUT drop position back to SOURCE time before storing it")
    func movingAMarkerStoresSourceTimeNotOutputTime() async throws {
        let sourceSeconds = 10.0
        let bundle = try await makeTrackLayoutTestBundle(seconds: sourceSeconds)
        var edl = EditDecisionList()
        edl.cuts = [Cut(range: TimeRange(start: 0, end: 2))]
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        let marker = LoggedEvent(timeSeconds: 5.0, kind: .marker, label: "m")
        let jumpPoints = MarkerJumpPoints.compute(events: [marker], keptRanges: built.keptRanges)
        let controller = PreviewController(built: built, jumpPoints: jumpPoints, bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: edl, events: [marker])

        // Drop the marker at OUTPUT 6.0. With a 2s head cut, output 6.0 is
        // source 8.0 — a wrong implementation that stores the OUTPUT value
        // directly would leave 6.0 in `events` instead of converting.
        state.moveMarker(id: marker.id, toOutput: 6.0)
        await state.waitForPendingSave()

        let stored = try #require(state.events.first { $0.id == marker.id })
        #expect(abs(stored.timeSeconds - 8.0) < 0.05)
    }

    @Test("Moving a marker with an unknown id is a no-op")
    func movingAnUnknownMarkerIsANoOp() async throws {
        let sourceSeconds = 10.0
        let bundle = try await makeTrackLayoutTestBundle(seconds: sourceSeconds)
        let built = try await CompositionBuilder.build(bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let marker = LoggedEvent(timeSeconds: 5.0, kind: .marker, label: "m")
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: EditDecisionList(), events: [marker])

        state.moveMarker(id: UUID(), toOutput: 1.0)
        await state.waitForPendingSave()

        #expect(state.events.first?.timeSeconds == 5.0)
    }

    @Test("Editing a marker with an unknown id is a no-op")
    func editingAnUnknownMarkerIsANoOp() async throws {
        let sourceSeconds = 10.0
        let bundle = try await makeTrackLayoutTestBundle(seconds: sourceSeconds)
        let built = try await CompositionBuilder.build(bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let marker = LoggedEvent(timeSeconds: 5.0, kind: .marker, label: "m")
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: EditDecisionList(), events: [marker])

        state.updateMarker(id: UUID(), label: "new", transcript: "new")
        await state.waitForPendingSave()

        #expect(state.events.first?.label == "m")
        #expect(state.events.first?.transcript == nil)
    }
}

// MARK: - Persistence across close/reopen, and undo

/// `.serialized` and touching `NSApplication.shared` once, for the same
/// reasons `CutRemovalPersistenceTests` does: this suite opens real,
/// front-ordered `EditorWindowController` windows via `DocumentOpener.open`.
@Suite(.serialized)
@MainActor
struct MarkerEditingPersistenceTests {
    init() { _ = NSApplication.shared }

    private func makeFixtureBundle(marker: LoggedEvent) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "track-layout-fixture-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 12)
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)
        try EventLog(events: [marker]).write(to: bundle)
        try EditDecisionList.fullRange().write(to: bundle)
        return url
    }

    @Test("Moving a marker persists, and the move survives reopening the document")
    func movePersistsAndSurvivesReopen() async throws {
        let marker = LoggedEvent(timeSeconds: 3.0, kind: .marker, label: "m")
        let url = try await makeFixtureBundle(marker: marker)
        defer { try? FileManager.default.removeItem(at: url) }

        try await EditorWindowTestGate.run {
            let first = try await DocumentOpener.open(bundleURL: url)
            first.moveMarkerForTesting(id: marker.id, toOutput: 7.0)
            await first.waitForPendingSaveForTesting()
            let moved = try #require(first.currentEventsForTesting().first { $0.id == marker.id })
            // A fresh recording has no cuts, so OUTPUT and SOURCE time
            // coincide here — the conversion itself is pinned separately by
            // `movingAMarkerStoresSourceTimeNotOutputTime`, which puts a cut
            // in the way specifically to discriminate the two.
            #expect(abs(moved.timeSeconds - 7.0) < 0.05)
            first.close()

            // The property that actually matters (Trap 3, "verify by
            // reopening"): not just "the in-memory events say 7.0" but that
            // CLOSING AND REOPENING the document shows the move too, and
            // that the bytes on disk agree.
            let second = try await DocumentOpener.open(bundleURL: url)
            defer { second.close() }
            let reopened = try #require(second.currentEventsForTesting().first { $0.id == marker.id })
            #expect(abs(reopened.timeSeconds - 7.0) < 0.05)

            let reloaded = try EventLog.read(from: SnittBundle(opening: url))
            let onDisk = try #require(reloaded.events.first { $0.id == marker.id })
            #expect(abs(onDisk.timeSeconds - 7.0) < 0.05)
        }
    }

    @Test("Editing a marker's label and transcript persists, and survives reopening the document")
    func editPersistsAndSurvivesReopen() async throws {
        let marker = LoggedEvent(timeSeconds: 3.0, kind: .marker, label: "old label")
        let url = try await makeFixtureBundle(marker: marker)
        defer { try? FileManager.default.removeItem(at: url) }

        try await EditorWindowTestGate.run {
            let first = try await DocumentOpener.open(bundleURL: url)
            first.updateMarkerForTesting(id: marker.id, label: "new label", transcript: "narration text")
            await first.waitForPendingSaveForTesting()
            first.close()

            let second = try await DocumentOpener.open(bundleURL: url)
            defer { second.close() }
            let reopened = try #require(second.currentEventsForTesting().first { $0.id == marker.id })
            #expect(reopened.label == "new label")
            #expect(reopened.transcript == "narration text")

            let reloaded = try EventLog.read(from: SnittBundle(opening: url))
            let onDisk = try #require(reloaded.events.first { $0.id == marker.id })
            #expect(onDisk.label == "new label")
            #expect(onDisk.transcript == "narration text")
        }
    }

    /// M5f whole-branch review, F5: this and `editIsUndoable` below asserted
    /// only `currentEventsForTesting()` — MEMORY. Stripping
    /// `applyAndSaveEvents()` out of `EditorTimelineState.restoreEvents`, so
    /// an undo never reaches `events.json` at all, left all 688 tests
    /// passing. The implementation was right; nothing held it there, and the
    /// cut-side equivalents (`EditorPersistenceTests.undoPersists`,
    /// `CutFoldTests`' "Undo after removing a cut persists the cut's
    /// return") both read disk. The disk read-back below is what makes that
    /// mutant fail.
    @Test("Moving a marker is undoable through the same UndoManager, and the undo reaches disk")
    func moveIsUndoable() async throws {
        let marker = LoggedEvent(timeSeconds: 3.0, kind: .marker, label: "m")
        let url = try await makeFixtureBundle(marker: marker)
        defer { try? FileManager.default.removeItem(at: url) }

        try await EditorWindowTestGate.run {
            let editor = try await DocumentOpener.open(bundleURL: url)
            defer { editor.close() }
            editor.moveMarkerForTesting(id: marker.id, toOutput: 7.0)
            await editor.waitForPendingSaveForTesting()
            let moved = try #require(editor.currentEventsForTesting().first { $0.id == marker.id })
            #expect(abs(moved.timeSeconds - 7.0) < 0.05)
            // The move itself is on disk before the undo — otherwise the
            // read-back after the undo could pass simply because nothing
            // ever wrote anything.
            let movedOnDisk = try #require(
                try EventLog.read(from: SnittBundle(opening: url)).events.first { $0.id == marker.id })
            #expect(abs(movedOnDisk.timeSeconds - 7.0) < 0.05)

            editor.undoManager?.undo()
            await editor.waitForPendingSaveForTesting()

            let restored = try #require(editor.currentEventsForTesting().first { $0.id == marker.id })
            #expect(abs(restored.timeSeconds - 3.0) < 0.05)

            let restoredOnDisk = try #require(
                try EventLog.read(from: SnittBundle(opening: url)).events.first { $0.id == marker.id })
            #expect(abs(restoredOnDisk.timeSeconds - 3.0) < 0.05,
                    "undo must persist, not merely revert the in-memory events")
        }
    }

    @Test("Editing a marker's label/transcript is undoable, and the undo reaches disk")
    func editIsUndoable() async throws {
        let marker = LoggedEvent(timeSeconds: 3.0, kind: .marker, label: "old")
        let url = try await makeFixtureBundle(marker: marker)
        defer { try? FileManager.default.removeItem(at: url) }

        try await EditorWindowTestGate.run {
            let editor = try await DocumentOpener.open(bundleURL: url)
            defer { editor.close() }
            editor.updateMarkerForTesting(id: marker.id, label: "new", transcript: "text")
            await editor.waitForPendingSaveForTesting()
            let editedOnDisk = try #require(
                try EventLog.read(from: SnittBundle(opening: url)).events.first { $0.id == marker.id })
            #expect(editedOnDisk.label == "new")

            editor.undoManager?.undo()
            await editor.waitForPendingSaveForTesting()

            let restored = try #require(editor.currentEventsForTesting().first { $0.id == marker.id })
            #expect(restored.label == "old")
            #expect(restored.transcript == nil)

            let restoredOnDisk = try #require(
                try EventLog.read(from: SnittBundle(opening: url)).events.first { $0.id == marker.id })
            #expect(restoredOnDisk.label == "old",
                    "undo must persist, not merely revert the in-memory events")
            #expect(restoredOnDisk.transcript == nil)
        }
    }
}
