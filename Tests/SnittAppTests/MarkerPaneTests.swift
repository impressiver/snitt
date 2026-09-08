import AVFoundation
import AppKit
import Foundation
import Testing
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// The chapter index derives itself from `events`, in OUTPUT time.
///
/// Every assertion here is about what the pane would show or do, not that a
/// method ran. The failure mode this guards is a list that looks right on an
/// unedited recording and silently lies once anything is cut — markers are
/// stored in SOURCE time and the panel navigates OUTPUT time, and this project
/// has already shipped one bug (M4b) from feeding a view the wrong clock.
@Suite(.serialized)
@MainActor
struct MarkerPaneTests {

    private func makeState(seconds: Double = 4.0,
                           edl: EditDecisionList = EditDecisionList(),
                           events: [LoggedEvent] = []) async throws -> EditorTimelineState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        // What the real edit path does after every change: the controller owns
        // the kept ranges and the marker points BOTH the panel and the timeline
        // lane read, and it learns about an EDL only through `apply`. A test
        // that skips this hands the state a cut the controller has never heard
        // of, and then asserts against a projection built from no cuts at all.
        try await controller.apply(edl: edl, events: events)
        controller.refreshJumpPoints(events: events)
        return EditorTimelineState(controller: controller, edl: edl, events: events)
    }

    // MARK: - Deriving the list

    @Test("Only markers appear, in time order, and unnamed ones still get a name")
    func chaptersAreMarkersInOrder() async throws {
        let state = try await makeState(events: [
            LoggedEvent(timeSeconds: 3.0, kind: .marker, label: "Outro"),
            LoggedEvent(timeSeconds: 2.0, kind: .click),      // not a chapter
            LoggedEvent(timeSeconds: 1.0, kind: .marker),     // unnamed
        ])
        let chapters = state.chapters
        #expect(chapters.count == 2, "clicks and keystrokes are not chapters")
        #expect(chapters[0].label == "Marker 1")
        #expect(chapters[0].hasCustomLabel == false)
        #expect(chapters[1].label == "Outro")
        #expect(chapters[1].hasCustomLabel == true)
    }

    @Test("A chapter's time is where it lands in the EDIT, not in the capture")
    func chapterTimeIsOutputTime() async throws {
        // One second removed from the front, so a marker at source 3s is at
        // 2s in the edited recording. Reading the stored time straight out
        // would say 3 and every seek from the panel would land a second late.
        let state = try await makeState(
            edl: EditDecisionList(cuts: [Cut(range: TimeRange(start: 0, end: 1))]),
            events: [LoggedEvent(timeSeconds: 3.0, kind: .marker, label: "After")])
        let time = try #require(state.chapters.first?.outputTime)
        #expect(abs(time - 2.0) < 0.05, "output time was \(time)")
    }

    @Test("A marker swallowed by a cut is still listed, marked as cut")
    func markerInsideACutIsListedNotDropped() async throws {
        // Dropping it would look like the marker was deleted by the cut. It
        // was not — it is still in events.json and moving the cut brings it
        // back.
        let state = try await makeState(
            edl: EditDecisionList(cuts: [Cut(range: TimeRange(start: 1, end: 3))]),
            events: [LoggedEvent(timeSeconds: 2.0, kind: .marker, label: "Buried")])
        let chapter = try #require(state.chapters.first)
        #expect(state.chapters.count == 1)
        #expect(chapter.isInsideCut)
        // Folded to the cut's edge — a real instant the playhead can reach, so
        // clicking the row seeks somewhere instead of doing nothing. The cut
        // removes 1s..3s, so the fold sits at 1s in the edit.
        #expect(abs(chapter.outputTime - 1.0) < 0.05, "fold at \(chapter.outputTime)")
    }

    @Test("The panel and the timeline lane place every marker identically")
    func panelAgreesWithTheLane() async throws {
        // Both must come from ONE projection. `MarkerJumpPoints.swift` warns
        // that a chapter list and a scrub bar disagreeing about the same
        // recording is worse than either alone, and the way they come to
        // disagree is two implementations of the same arithmetic. This fails
        // the moment the panel re-derives its own.
        let state = try await makeState(
            edl: EditDecisionList(cuts: [Cut(range: TimeRange(start: 1, end: 3))]),
            events: [
                LoggedEvent(timeSeconds: 0.5, kind: .marker, label: "Before"),
                LoggedEvent(timeSeconds: 2.0, kind: .marker, label: "Buried"),
                LoggedEvent(timeSeconds: 3.5, kind: .marker, label: "After"),
            ])
        let lane = state.displayState(playhead: 0).markerPoints
        let panel = state.chapters
        #expect(panel.count == lane.count)
        for (chapter, point) in zip(panel, lane) {
            #expect(chapter.id == point.id)
            #expect(abs(chapter.outputTime - point.timeSeconds) < 0.001,
                    "panel \(chapter.outputTime) vs lane \(point.timeSeconds)")
            #expect(chapter.isInsideCut == point.isInsideCut)
        }
    }

    // MARK: - Highlighting

    @Test("A chapter stays current until the next one starts")
    func currentChapterSpansToTheNext() async throws {
        let state = try await makeState(events: [
            LoggedEvent(timeSeconds: 0.0, kind: .marker, label: "One"),
            LoggedEvent(timeSeconds: 2.0, kind: .marker, label: "Two"),
        ])
        let ids = state.chapters.map(\.id)
        // Halfway between the two: an implementation that highlights only
        // when the playhead sits ON a marker highlights nothing here, which
        // means nothing is ever highlighted — a marker has no duration.
        #expect(state.currentChapterID(atOutputSeconds: 1.0) == ids[0])
        #expect(state.currentChapterID(atOutputSeconds: 2.5) == ids[1])
        #expect(state.currentChapterID(atOutputSeconds: 2.0) == ids[1],
                "landing exactly on a chapter should select it, not the one before")
    }

    // MARK: - Editing

    @Test("Adding a chapter stores it in source time, not playhead time")
    func addMarkerConvertsFromOutputTime() async throws {
        let state = try await makeState(
            edl: EditDecisionList(cuts: [Cut(range: TimeRange(start: 0, end: 1))]))
        state.addMarker(atOutput: 1.0)          // 1s into the EDIT
        let event = try #require(state.events.first { $0.kind == .marker })
        // Storing the playhead value verbatim would write 1.0, and the marker
        // would drift every time the cut changed.
        #expect(abs(event.timeSeconds - 2.0) < 0.05, "stored \(event.timeSeconds)")
    }

    @Test("Deleting a chapter removes it, and undo brings it back")
    func deleteIsUndoable() async throws {
        let state = try await makeState(events: [
            LoggedEvent(timeSeconds: 1.0, kind: .marker, label: "Gone"),
        ])
        let undo = UndoManager()
        state.undoManager = undo
        let id = try #require(state.chapters.first?.id)

        state.deleteMarker(id: id)
        #expect(state.chapters.isEmpty)

        undo.undo()
        #expect(state.chapters.count == 1, "delete was not undoable")
        #expect(state.chapters.first?.label == "Gone")
    }

    @Test("Renaming a chapter keeps its narration text")
    func renamePreservesTranscript() async throws {
        // The real hazard: `updateMarker` writes label AND transcript
        // together, so a rename that forgets to pass the existing transcript
        // silently destroys narration the sheet had set.
        let state = try await makeState(events: [
            LoggedEvent(timeSeconds: 1.0, kind: .marker,
                        label: "Old", transcript: "the narration"),
        ])
        let id = try #require(state.chapters.first?.id)
        state.renameMarker(id: id, to: "New")

        let chapter = try #require(state.chapters.first)
        #expect(chapter.label == "New")
        #expect(chapter.transcript == "the narration", "renaming destroyed the transcript")
    }

    @Test("Renaming to blank restores the generated name rather than an empty row")
    func blankRenameFallsBack() async throws {
        let state = try await makeState(events: [
            LoggedEvent(timeSeconds: 1.0, kind: .marker, label: "Named"),
        ])
        let id = try #require(state.chapters.first?.id)
        state.renameMarker(id: id, to: "   ")
        let chapter = try #require(state.chapters.first)
        #expect(chapter.hasCustomLabel == false)
        #expect(chapter.label == "Marker 1", "a blank name would leave an unclickable empty row")

        // The STORED value must be nil, not "". The panel falls back on either
        // one, so display alone cannot tell them apart — but `WebVTTChapters`
        // does `marker.label ?? "Chapter N"`, a nil-coalesce rather than an
        // empty check, so an empty string exports a chapter with no title at
        // all. Asserting only what the pane shows passes against exactly that
        // bug.
        let stored = try #require(state.events.first { $0.kind == .marker })
        #expect(stored.label == nil, "stored \(String(describing: stored.label))")
    }

    // MARK: - Presentation

    @Test("Timestamps read as chapter times, and grow an hours field only when needed")
    func timestampFormatting() {
        #expect(MarkerPane.timestamp(0) == "0:00")
        #expect(MarkerPane.timestamp(65) == "1:05")
        #expect(MarkerPane.timestamp(3725) == "1:02:05")
        // Truncates rather than rounds: a chapter at 1.9s is inside the
        // second beginning at 1, and rounding up would show a time the
        // playhead has not reached.
        #expect(MarkerPane.timestamp(1.9) == "0:01")
    }
}
