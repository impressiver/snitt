// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
import Combine
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

    @Test("A hover while PLAYING leaves playback alone")
    func hoverWhilePlayingIsInert() async throws {
        // Product owner: while playing, a scrub does not change playback.
        // Only a paused timeline shows the hovered frame in the main window.
        //
        // The hover aims 11s ahead of a run starting at 0, so "below 9" means
        // no seek with seconds of slack for a loaded machine. A 2s bound was
        // the kind playback overran in the full suite.
        let state = try await makeState(seconds: 12.0)
        state.togglePlayback()
        #expect(state.isPlaying, "precondition: playing")

        state.hoverPreview(toSource: 11.0)
        await state.waitForHoverPreview()
        #expect(state.isPlaying, "a hover must not pause")
        #expect(state.currentOutputSeconds < 9.0,
                "a hover while playing must not seek, got \(state.currentOutputSeconds)")
        #expect(state.displayState(playhead: 0).markedPlayhead == nil,
                "nothing was scrubbed, so there is no second playhead")

        state.hoverPreview(toSource: nil)
        await state.waitForHoverPreview()
        #expect(state.isPlaying, "an exit must not pause")
        #expect(state.currentOutputSeconds < 9.0,
                "an exit must not seek either, got \(state.currentOutputSeconds)")
        state.pauseForAgent()
    }

    @Test("Pausing mid-hover starts previewing on the next move, and the exit returns to the pause")
    func pauseDuringHoverStartsPreviewing() async throws {
        let state = try await makeState()
        state.onScrub(1.0)
        await state.waitForPendingSeek()
        state.togglePlayback()
        state.hoverPreview(toSource: 6.0)   // inert: playing
        await state.waitForHoverPreview()

        state.togglePlayback()              // pause, pointer still on the strip
        let pausedAt = state.currentOutputSeconds
        state.hoverPreview(toSource: 5.0)
        await state.waitForHoverPreview()
        #expect(abs(state.currentOutputSeconds - 5.0) < 0.2,
                "paused now, so the hover previews, got \(state.currentOutputSeconds)")
        state.hoverPreview(toSource: nil)
        await state.waitForHoverPreview()
        #expect(!state.isPlaying)
        #expect(abs(state.currentOutputSeconds - pausedAt) < 0.2,
                "the exit returns to where playback was paused, got \(state.currentOutputSeconds)")
    }

    @Test("A click during a hover over playback plays on from the click")
    func clickDuringPlayingHoverPlaysOn() async throws {
        // The click jumps BACKWARDS (8s to 1s), so "below 6" proves it landed
        // with seconds of slack for a loaded machine: a forward jump needed an
        // upper bound that playback overran in the full suite.
        let state = try await makeState(seconds: 12.0)
        state.onScrub(8.0)
        await state.waitForPendingSeek()
        state.togglePlayback()

        state.hoverPreview(toSource: 3.0)   // inert: playing
        await state.waitForHoverPreview()
        state.onScrub(1.0)
        await state.waitForPendingSeek()
        state.hoverPreview(toSource: 4.0)   // still inert: still playing
        await state.waitForHoverPreview()
        state.hoverPreview(toSource: nil)
        await state.waitForHoverPreview()

        #expect(state.isPlaying, "the click keeps playback going")
        #expect(state.currentOutputSeconds >= 0.95 && state.currentOutputSeconds < 6.0,
                "playback continues from the click, got \(state.currentOutputSeconds)")
        state.pauseForAgent()
    }

    @Test("Leaving a hover over a PAUSED timeline stays paused")
    func exitFromPausedHoverStaysPaused() async throws {
        let state = try await makeState()
        state.onScrub(1.0)
        await state.waitForPendingSeek()
        state.hoverPreview(toSource: 5.0)
        await state.waitForHoverPreview()
        state.hoverPreview(toSource: nil)
        await state.waitForHoverPreview()
        #expect(!state.isPlaying)
    }

    @Test("Pressing play mid-hover plays from the hovered frame and ends the hover")
    func playDuringHoverAbandonsIt() async throws {
        // Positions far apart (pre-hover 0.5s, hovered 3s, next move 11s) so
        // each bound carries seconds of slack for a loaded machine.
        let state = try await makeState(seconds: 12.0)
        state.onScrub(0.5)
        await state.waitForPendingSeek()
        state.hoverPreview(toSource: 3.0)
        await state.waitForHoverPreview()

        state.togglePlayback()
        // The pointer is still in the band and still moving.
        state.hoverPreview(toSource: 11.0)
        await state.waitForHoverPreview()
        #expect(state.isPlaying, "a move after play must not pause again")
        #expect(state.currentOutputSeconds < 9.0,
                "a move after play must not seek, got \(state.currentOutputSeconds)")
        state.hoverPreview(toSource: nil)
        await state.waitForHoverPreview()
        #expect(state.isPlaying, "the exit must not stop playback")
        #expect(state.currentOutputSeconds > 2.5,
                "the exit must not restore the pre-hover position, got \(state.currentOutputSeconds)")
        state.pauseForAgent()
    }

    @Test("Pressing play mid-hover, then leaving without moving, keeps playing from the hovered frame")
    func playThenExitWithoutMovingKeepsPosition() async throws {
        let state = try await makeState()
        state.onScrub(1.0)
        await state.waitForPendingSeek()
        state.hoverPreview(toSource: 4.0)
        await state.waitForHoverPreview()

        state.togglePlayback()
        state.hoverPreview(toSource: nil)
        await state.waitForHoverPreview()
        #expect(state.isPlaying)
        #expect(state.currentOutputSeconds > 3.5,
                "the exit must not restore over playback, got \(state.currentOutputSeconds)")
        state.pauseForAgent()
    }

    @Test("While scrubbing, the timeline is told where the marked playhead is")
    func markedPlayheadIsShownOnlyWhileScrubbing() async throws {
        // During a hover the drawn playhead follows the player, i.e. the
        // pointer, so the position the exit returns to is otherwise nowhere
        // on screen.
        let state = try await makeState()
        state.onScrub(2.0)
        await state.waitForPendingSeek()
        #expect(state.displayState(playhead: 2.0).markedPlayhead == nil,
                "no second indicator when not scrubbing")

        state.hoverPreview(toSource: 6.0)
        await state.waitForHoverPreview()
        let marked = state.displayState(playhead: 6.0).markedPlayhead
        #expect(marked.map { abs($0 - 2.0) < 0.05 } == true,
                "the indicator marks the pre-hover position, got \(String(describing: marked))")

        state.onScrub(4.0)
        await state.waitForPendingSeek()
        let recommitted = state.displayState(playhead: 4.0).markedPlayhead
        #expect(recommitted.map { abs($0 - 4.0) < 0.05 } == true,
                "a click moves the indicator, got \(String(describing: recommitted))")

        state.hoverPreview(toSource: nil)
        await state.waitForHoverPreview()
        #expect(state.displayState(playhead: 4.0).markedPlayhead == nil,
                "the indicator goes when the scrub ends")
    }

    @Test("A click during playback does not haunt a later hover's snap-back")
    func clickDuringPlaybackDoesNotHauntSnapBack() async throws {
        // A click no longer pauses, so its destination must disarm once the
        // seek lands. Left armed, playback ran on past it and the next hover
        // snapped back to the old click instead of to where playback paused.
        let state = try await makeState(seconds: 12.0)
        state.togglePlayback()
        state.onScrub(1.0)                          // click while playing
        await state.waitForPendingSeek()
        await state.controller.seek(toSeconds: 5.0) // playback moves on
        state.pauseForAgent()
        state.refreshPlaybackState()

        state.hoverPreview(toSource: 9.0)
        await state.waitForHoverPreview()
        state.hoverPreview(toSource: nil)
        await state.waitForHoverPreview()
        #expect(abs(state.currentOutputSeconds - 5.0) < 0.2,
                "snap-back went to the old click, got \(state.currentOutputSeconds)")
    }

    @Test("A click while a restore is in flight wins over the restore")
    func clickOutranksInFlightRestore() async throws {
        let state = try await makeState()
        state.onScrub(1.0)
        await state.waitForPendingSeek()
        state.hoverPreview(toSource: 5.0)
        await state.waitForHoverPreview()
        state.hoverPreview(toSource: nil)   // restore to 1 in flight
        state.onScrub(3.0)                  // click in another lane
        state.hoverPreview(toSource: 6.0)   // back onto the strip
        await state.waitForHoverPreview()
        state.hoverPreview(toSource: nil)
        await state.waitForHoverPreview()
        await state.waitForPendingSeek()
        #expect(abs(state.currentOutputSeconds - 3.0) < 0.2,
                "exit returned to the superseded restore, got \(state.currentOutputSeconds)")
    }

    @Test("Playback started by an agent mid-hover is not yanked back on exit")
    func agentPlayThenExitKeepsPlaying() async throws {
        let state = try await makeState(seconds: 12.0)
        state.onScrub(1.0)
        await state.waitForPendingSeek()
        state.hoverPreview(toSource: 8.0)
        await state.waitForHoverPreview()
        state.playForAgent()
        state.hoverPreview(toSource: nil)
        await state.waitForHoverPreview()
        #expect(state.currentOutputSeconds > 6.0,
                "the exit restored over agent-started playback, got \(state.currentOutputSeconds)")
        state.pauseForAgent()
    }

    @Test("Ending a hover publishes nothing, because it can run inside a view update")
    func exitDoesNotPublish() async throws {
        // A geometry change ends the hover from inside `updateNSView`, and
        // SwiftUI forbids publishing from within a view update.
        let state = try await makeState()
        state.onScrub(1.0)
        await state.waitForPendingSeek()
        state.hoverPreview(toSource: 5.0)
        await state.waitForHoverPreview()

        var published = 0
        let sink = state.objectWillChange.sink { _ in published += 1 }
        state.hoverPreview(toSource: nil)
        sink.cancel()
        #expect(published == 0, "the exit published \(published) time(s)")
        await state.waitForHoverPreview()
    }

    @Test("A click during a hover publishes, so the marked playhead redraws")
    func recommitPublishes() async throws {
        // A paused scrub with a still pointer moves no playhead, so nothing
        // else would re-render the marked line at the clicked position.
        let state = try await makeState()
        state.onScrub(1.0)
        await state.waitForPendingSeek()
        state.hoverPreview(toSource: 5.0)
        await state.waitForHoverPreview()

        var published = 0
        let sink = state.objectWillChange.sink { _ in published += 1 }
        state.onScrub(5.0)
        sink.cancel()
        #expect(published > 0, "the recommit did not publish")
        await state.waitForPendingSeek()
    }

    @Test("Pressing play mid-hover drops the dimmed playhead at once")
    func playClearsTheMarkedPlayhead() async throws {
        // Otherwise the marked line keeps drawing through playback until the
        // pointer next moves, marking a position nothing will return to.
        let state = try await makeState()
        state.onScrub(1.0)
        await state.waitForPendingSeek()
        state.hoverPreview(toSource: 4.0)
        await state.waitForHoverPreview()
        #expect(state.displayState(playhead: 4.0).markedPlayhead != nil, "precondition")

        state.togglePlayback()
        #expect(state.displayState(playhead: 4.0).markedPlayhead == nil)
        state.pauseForAgent()
    }

    @Test("A click beats a preview seek still queued behind it")
    func clickOutranksQueuedPreview() async throws {
        let state = try await makeState()
        state.onScrub(0.5)
        await state.waitForPendingSeek()

        state.hoverPreview(toSource: 3.0)   // in flight
        state.hoverPreview(toSource: 4.0)   // queued behind it
        state.onScrub(6.0)
        await state.waitForPendingSeek()
        await state.waitForHoverPreview()
        #expect(abs(state.currentOutputSeconds - 6.0) < 0.2,
                "the click is where the playhead lands, got \(state.currentOutputSeconds)")
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
