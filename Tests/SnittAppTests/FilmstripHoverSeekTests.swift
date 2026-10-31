// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// What a filmstrip hover does to playback: previews while paused, restores
/// on exit, and never touches the committed position.
///
/// The hard part is not the seeking, it is the RESTORING. `pendingSeekTarget`
/// exists because "every seek in this editor hands the work to a `Task`, so
/// `player.currentTime()` still reports the OLD position for a beat
/// afterwards" — so "where the playhead was before the hover" cannot simply
/// be read off the player at hover time. These tests pin the answer the
/// editor actually uses.
/// Its own thin wrapper around the target-shared `writeSyntheticMovie`,
/// following the convention `EditorTimelineStateTests` states explicitly:
/// "Swift Testing target sources don't share PRIVATE helpers across files, so
/// this file gets its own thin wrapper". Widening that file's helper instead
/// would have changed an unrelated file's API for this one's convenience.
@MainActor
private func makeHoverTestBundle(seconds: Double) async throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    let bundle = try SnittBundle(creatingAt: url)
    try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds)
    return bundle
}

@MainActor
struct FilmstripHoverSeekTests {

    private func makeState(seconds: Double = 8.0) async throws -> EditorTimelineState {
        let bundle = try await makeHoverTestBundle(seconds: seconds)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        return EditorTimelineState(controller: controller,
                                   edl: EditDecisionList(), events: [])
    }

    @Test("A hover while paused moves the picture")
    func hoverWhilePausedSeeks() async throws {
        let state = try await makeState()
        state.onScrub(1.0)
        await state.waitForPendingSeek()

        state.hoverPreview(toSource: 5.0)
        await state.waitForHoverPreview()
        #expect(abs(state.currentOutputSeconds - 5.0) < 0.2,
                "the previewed instant is where the player went, got \(state.currentOutputSeconds)")
    }

    @Test("A hover does not record a destination, so navigation is unaffected")
    func hoverLeavesTheCommittedPositionAlone() async throws {
        // `pendingSeekTarget` is what mark-to-mark navigation reasons FROM.
        // A hover writing it would make Next/Previous step from wherever the
        // pointer happened to be resting, which is the defect its own doc
        // comment describes arriving by a new route.
        let state = try await makeState()
        state.onScrub(1.0)
        await state.waitForPendingSeek()
        let committed = state.pendingSeekTargetForTesting

        state.hoverPreview(toSource: 6.0)
        await state.waitForHoverPreview()
        #expect(state.pendingSeekTargetForTesting == committed,
                "a hover must not overwrite the editor's recorded destination")
    }

    @Test("Leaving the filmstrip snaps back to the last clicked position")
    func exitRestoresTheClickedPosition() async throws {
        let state = try await makeState()
        state.onScrub(2.0)
        await state.waitForPendingSeek()

        state.hoverPreview(toSource: 7.0)
        await state.waitForHoverPreview()
        #expect(abs(state.currentOutputSeconds - 7.0) < 0.2, "precondition: the preview moved")

        state.hoverPreview(toSource: nil)
        await state.waitForHoverPreview()
        #expect(abs(state.currentOutputSeconds - 2.0) < 0.2,
                "the exit returns to the clicked position, got \(state.currentOutputSeconds)")
    }

    @Test("A click DURING a hover becomes the position to snap back to")
    func clickWhileHoveringRecommits() async throws {
        // The interaction the plan missed until it was written down: hover,
        // click what you are looking at, keep hovering, then leave. Snapping
        // back to where the pointer ARRIVED would undo the click.
        let state = try await makeState()
        state.onScrub(1.0)
        await state.waitForPendingSeek()

        state.hoverPreview(toSource: 4.0)
        await state.waitForHoverPreview()
        // The click the user makes while looking at the previewed frame.
        state.onScrub(4.0)
        await state.waitForPendingSeek()
        // Still hovering afterwards, then the pointer leaves.
        state.hoverPreview(toSource: 6.0)
        await state.waitForHoverPreview()
        state.hoverPreview(toSource: nil)
        await state.waitForHoverPreview()

        #expect(abs(state.currentOutputSeconds - 4.0) < 0.2,
                "the exit must honour the click, not the position the hover began from, got \(state.currentOutputSeconds)")
    }

    @Test("A hover while PLAYING is ignored and does not stop playback")
    func hoverWhilePlayingIsInert() async throws {
        // The product owner's choice: preview only while paused. A hover that
        // seeks mid-playback fights the playback clock, and one that paused
        // would stop the picture every time the pointer crossed the timeline.
        let state = try await makeState()
        state.togglePlayback()
        #expect(state.isPlaying, "precondition: playing")

        state.hoverPreview(toSource: 6.0)
        await state.waitForHoverPreview()
        #expect(state.isPlaying, "a hover must not pause")
        // AND it must not move the picture. Asserting only that playback
        // continued was too weak to be worth writing: a preview does not
        // pause, so deleting the `isPlaying` guard altogether left that
        // assertion passing. Playback from 0 cannot have reached 6s in the
        // moment this takes, so a position anywhere near the hovered instant
        // means the hover seeked when it should have done nothing.
        #expect(state.currentOutputSeconds < 2.0,
                "a hover while playing must not seek, got \(state.currentOutputSeconds)")

        // And the exit must not yank the picture back either, since nothing
        // was previewed to begin with.
        state.hoverPreview(toSource: nil)
        await state.waitForHoverPreview()
        #expect(state.isPlaying, "an exit must not pause")
        state.togglePlayback()
    }

    @Test("Rapid hovers coalesce to the last one")
    func rapidHoversCoalesce() async throws {
        // `mouseMoved` arrives at pointer speed, far faster than an
        // `AVPlayer.seek` completes. Without coalescing the seeks queue and
        // the picture walks through every intermediate position after the
        // pointer has stopped.
        let state = try await makeState()
        state.onScrub(0.5)
        await state.waitForPendingSeek()

        for t in stride(from: 1.0, through: 7.0, by: 0.5) {
            state.hoverPreview(toSource: t)
        }
        await state.waitForHoverPreview()
        #expect(abs(state.currentOutputSeconds - 7.0) < 0.3,
                "the player ends at the LAST hovered instant, got \(state.currentOutputSeconds)")
    }

    @Test("A hover that starts before a click's seek has landed still snaps back to it")
    func exitHonoursAnInFlightCommittedSeek() async throws {
        // THE REASON `hoverReturnTarget` reads `pendingSeekTarget` FIRST.
        //
        // Deliberately does NOT settle after the scrub: the point is to hover
        // while the committed seek is still in flight, which is what happens
        // when you click the timeline and sweep up onto the filmstrip in one
        // motion. `player.currentTime()` still reports the pre-click position
        // for a beat ("every seek in this editor hands the work to a `Task`"),
        // so a hover that captured the player's clock would snap back to
        // wherever the playhead was BEFORE the click.
        let state = try await makeState()
        state.onScrub(1.0)
        await state.waitForPendingSeek()

        // Second click, immediately followed by a hover, with no settle.
        state.onScrub(6.0)
        state.hoverPreview(toSource: 3.0)
        await state.waitForHoverPreview()
        state.hoverPreview(toSource: nil)
        await state.waitForHoverPreview()
        await state.waitForPendingSeek()

        #expect(abs(state.currentOutputSeconds - 6.0) < 0.2,
                "the exit must return to the click that was still in flight, got \(state.currentOutputSeconds)")
    }

    @Test("A hover registers nothing on the undo stack")
    func hoverIsNotUndoable() async throws {
        // Undo is a binding constraint in this editor and a preview is not an
        // edit. A hover that pushed an undo entry would make ⌘Z after moving
        // the mouse do something invisible.
        let state = try await makeState()
        let manager = UndoManager()
        state.undoManager = manager

        state.hoverPreview(toSource: 3.0)
        await state.waitForHoverPreview()
        state.hoverPreview(toSource: nil)
        await state.waitForHoverPreview()

        #expect(!manager.canUndo, "a preview is not an edit")
    }
}

/// Coalescing, measured in SEEKS rather than in playhead position.
///
/// Separate suite because it is the only thing here that reads
/// `PreviewController` rather than `EditorTimelineState`.
///
/// **What this does and does not pin.** It pins that a pointer sweep does not
/// become a seek per event. It does NOT pin the `hoverSeekTask == nil` guard,
/// and the mutation run is what established that: delete the guard and this
/// test still passes, because the single `hoverSeekTarget` slot is what
/// collapses the sweep — thirteen tasks all drain one target, so twelve of
/// them find it already nil and seek nothing. See `Tests/mutants.txt` for
/// why that guard is kept anyway.
@MainActor
struct FilmstripHoverCoalescingTests {

    @Test("Many hover events in one turn issue far fewer seeks than events")
    func hoversCoalesceIntoFewSeeks() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 8.0)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller,
                                        edl: EditDecisionList(), events: [])

        // Thirteen events in a single main-actor turn, which is what a pointer
        // sweeping across the filmstrip actually delivers.
        var events = 0
        for t in stride(from: 1.0, through: 7.0, by: 0.5) {
            state.hoverPreview(toSource: t)
            events += 1
        }
        await state.waitForHoverPreview()

        #expect(events == 13, "precondition: the sweep really was 13 events")
        #expect(controller.previewSeekCount < events,
                "13 events must not become 13 seeks, got \(controller.previewSeekCount)")
        #expect(controller.previewSeekCount <= 2,
                "one in flight plus at most one queued, got \(controller.previewSeekCount)")
    }
}
