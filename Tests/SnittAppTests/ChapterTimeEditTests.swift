// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AVFoundation
import Combine
import AppKit
import Foundation
import Testing
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// A chapter's TIME is editable in the panel, not only its name.
///
/// The gesture this replaces is dragging the marker on the timeline lane —
/// pixel-accurate work for a value the person already knows ("the demo starts
/// at 1:30"), and impossible to do precisely when the whole recording is
/// zoomed to fit.
///
/// Every assertion here is on the resulting chapter list — where the chapter
/// actually ENDED UP — rather than on "moveMarker was called". This project
/// has found twenty-six tests that asserted a property adjacent to the one
/// that mattered, and "a setter ran" is the classic shape of that mistake.
@Suite(.serialized)
@MainActor
struct ChapterTimeEditTests {

    private func makeState(seconds: Double = 6.0,
                           edl: EditDecisionList = EditDecisionList(),
                           events: [LoggedEvent]) async throws -> EditorTimelineState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        try await controller.apply(edl: edl, events: events)
        controller.refreshJumpPoints(events: events)
        return EditorTimelineState(controller: controller, edl: edl, events: events)
    }

    // MARK: - Reading what a person types

    @Test("m:ss round-trips through the field it is displayed in")
    func timestampRoundTrips() {
        // The field is PRE-FILLED with `timestamp(...)`, so the parser must
        // read that exact format back. A parser that only accepted bare
        // seconds would reject its own placeholder — and every edit that
        // touched only the name would silently reset the time.
        for seconds in [0.0, 5.0, 65.0, 599.0, 3725.0] {
            let text = MarkerPane.timestamp(seconds)
            #expect(MarkerPane.parseTimestamp(text) == seconds,
                    "\(seconds) rendered as \(text)")
        }
    }

    @Test("A bare number is seconds, not minutes")
    func bareNumberIsSeconds() {
        // "45" means 45 seconds. Reading it as 45 MINUTES would put the
        // chapter past the end of almost every recording, where it would be
        // clamped to the end — a plausible implementation (treat the first
        // field as minutes always) that fails loudly here and nowhere else.
        #expect(MarkerPane.parseTimestamp("45") == 45)
        #expect(MarkerPane.parseTimestamp("0") == 0)
    }

    @Test("Hours are read when a recording is long enough to need them")
    func hoursAreRead() {
        #expect(MarkerPane.parseTimestamp("1:02:03") == 3723)
    }

    @Test("Surrounding whitespace is not a syntax error")
    func whitespaceIsTolerated() {
        #expect(MarkerPane.parseTimestamp("  1:05  ") == 65)
    }

    @Test("Text that is not a time is refused rather than read as zero")
    func garbageIsRefused() {
        // Each of these is a real thing a field can contain mid-edit or by
        // accident. Returning 0 for any of them moves the chapter to the
        // start of the recording — a destructive answer to "I do not
        // understand", and one the caller cannot distinguish from a
        // deliberate 0:00.
        for text in ["", "   ", "intro", "1:", ":30", "1:2:3:4", "-5", "1.2.3", "٥"] {
            #expect(MarkerPane.parseTimestamp(text) == nil, "accepted \(text.debugDescription)")
        }
    }

    @Test("A seconds field of 60 or more is a typo, not a carry")
    func overflowingSecondsRefused() {
        // "1:75" is somebody mistyping, not a request for 2:15. Silently
        // carrying it puts the chapter somewhere they did not ask for and
        // did not see, because the field closes on commit.
        #expect(MarkerPane.parseTimestamp("1:75") == nil)
        #expect(MarkerPane.parseTimestamp("1:60") == nil)
        #expect(MarkerPane.parseTimestamp("1:59") == 119)
    }

    // MARK: - Applying the edit

    @Test("Editing the time moves the chapter to where it was typed")
    func editingTheTimeMovesTheChapter() async throws {
        let marker = LoggedEvent(timeSeconds: 1.0, kind: .marker, label: "Intro")
        let state = try await makeState(events: [marker])

        state.applyChapterEdit(id: marker.id, timeText: "0:04", label: "Intro")

        let chapter = try #require(state.chapters.first)
        #expect(abs(chapter.outputTime - 4.0) < 0.05, "landed at \(chapter.outputTime)")
    }

    @Test("The typed time is OUTPUT time, so cuts before it are accounted for")
    func typedTimeIsOutputTime() async throws {
        // The panel SHOWS output time, so a person typing 0:02 means "two
        // seconds into the edited recording". Storing 2.0 straight into the
        // event would put it at 2s of the CAPTURE, which with a second cut
        // from the front is 1s in the edit — the exact class of bug M4b
        // already shipped once.
        let marker = LoggedEvent(timeSeconds: 4.0, kind: .marker, label: "Later")
        let state = try await makeState(
            edl: EditDecisionList(cuts: [Cut(range: TimeRange(start: 0, end: 1))]),
            events: [marker])

        state.applyChapterEdit(id: marker.id, timeText: "0:02", label: "Later")

        let chapter = try #require(state.chapters.first)
        #expect(abs(chapter.outputTime - 2.0) < 0.05, "landed at \(chapter.outputTime)")
        // And the stored SOURCE time is one second later than the output
        // time, which is what proves the conversion happened rather than
        // the number being copied through.
        let stored = try #require(state.events.first?.timeSeconds)
        #expect(abs(stored - 3.0) < 0.05, "stored \(stored)")
    }

    @Test("A time past the end is clamped, not ignored")
    func timePastTheEndIsClamped() async throws {
        // Dropping the edit would look like the field is broken. A drag
        // cannot go past the end because there is no timeline there; typing
        // should behave the same way.
        let marker = LoggedEvent(timeSeconds: 1.0, kind: .marker, label: "End")
        let state = try await makeState(seconds: 6.0, events: [marker])

        state.applyChapterEdit(id: marker.id, timeText: "9:00", label: "End")

        let chapter = try #require(state.chapters.first)
        #expect(chapter.outputTime > 1.5, "an ignored edit leaves it at 1.0; got \(chapter.outputTime)")
        #expect(chapter.outputTime <= 6.01, "past the end: \(chapter.outputTime)")
    }

    @Test("An unreadable time leaves the chapter where it was, and still renames")
    func unreadableTimeKeepsThePosition() async throws {
        let marker = LoggedEvent(timeSeconds: 2.0, kind: .marker, label: "Old")
        let state = try await makeState(events: [marker])

        state.applyChapterEdit(id: marker.id, timeText: "not a time", label: "New")

        let chapter = try #require(state.chapters.first)
        #expect(abs(chapter.outputTime - 2.0) < 0.05, "moved to \(chapter.outputTime)")
        #expect(chapter.label == "New", "the name half of the edit was dropped too")
    }

    @Test("Both fields commit together, not one of them")
    func bothFieldsCommit() async throws {
        let marker = LoggedEvent(timeSeconds: 1.0, kind: .marker, label: "Old")
        let state = try await makeState(events: [marker])

        state.applyChapterEdit(id: marker.id, timeText: "0:03", label: "New")

        let chapter = try #require(state.chapters.first)
        #expect(chapter.label == "New")
        #expect(abs(chapter.outputTime - 3.0) < 0.05)
    }

    @Test("One undo restores the whole edit")
    func oneUndoRestoresBothFields() async throws {
        // Guards a new mutation path forgetting to register undo at all —
        // `moveMarker` and `updateMarker` both do, and a third method that
        // does not is silently unundoable.
        //
        // It does NOT rule out `moveMarker` + `renameMarker`, and an earlier
        // version of this comment claimed it did: `UndoManager.groupsByEvent`
        // is on by default, so two registrations in the same run-loop pass
        // collapse into one ⌘Z. `oneEditPublishesOnce` below is the test that
        // actually separates the two implementations.
        let marker = LoggedEvent(timeSeconds: 1.0, kind: .marker, label: "Old")
        let state = try await makeState(events: [marker])
        let undo = UndoManager()
        state.undoManager = undo

        state.applyChapterEdit(id: marker.id, timeText: "0:03", label: "New")
        undo.undo()

        let chapter = try #require(state.chapters.first)
        #expect(chapter.label == "Old", "the name was not restored")
        #expect(abs(chapter.outputTime - 1.0) < 0.05, "the time was not restored: \(chapter.outputTime)")
    }

    @Test("An edit publishes once, so no half-applied row is ever rendered")
    func oneEditPublishesOnce() async throws {
        // The failure this catches is a flash: `moveMarker` then
        // `renameMarker` publishes `events` twice, and the first publish
        // carries the NEW time with the OLD name. Every view watching the
        // array — the panel and the timeline lane both do — renders that
        // combination for a frame. Nobody typed it.
        //
        // Counting publishes rather than eyeballing a frame, because a frame
        // is exactly the kind of thing a test cannot see and a person can.
        let marker = LoggedEvent(timeSeconds: 1.0, kind: .marker, label: "Old")
        let state = try await makeState(events: [marker])

        var publishes = 0
        let token = state.$events.dropFirst().sink { _ in publishes += 1 }
        defer { token.cancel() }

        state.applyChapterEdit(id: marker.id, timeText: "0:03", label: "New")

        #expect(publishes == 1, "published \(publishes) times for one edit")
    }

    @Test("A blank name falls back to the generated label, as renaming does")
    func blankNameFallsBack() async throws {
        let marker = LoggedEvent(timeSeconds: 1.0, kind: .marker, label: "Old")
        let state = try await makeState(events: [marker])

        state.applyChapterEdit(id: marker.id, timeText: "0:02", label: "   ")

        let chapter = try #require(state.chapters.first)
        #expect(chapter.hasCustomLabel == false, "stored a whitespace name")
        #expect(chapter.label == "Marker 1")
    }

    @Test("Editing a chapter that is no longer there does nothing")
    func editingAMissingChapterIsANoOp() async throws {
        let marker = LoggedEvent(timeSeconds: 1.0, kind: .marker, label: "Only")
        let state = try await makeState(events: [marker])

        state.applyChapterEdit(id: UUID(), timeText: "0:03", label: "Ghost")

        #expect(state.chapters.count == 1)
        let chapter = try #require(state.chapters.first)
        #expect(chapter.label == "Only")
        #expect(abs(chapter.outputTime - 1.0) < 0.05)
    }
}
