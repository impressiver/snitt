// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AVFoundation
import AppKit
import Foundation
import Testing
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// A marker drag has to show where it landed, immediately.
///
/// The bug: `displayState` read `controller.markerTrackPoints`, a cache
/// refreshed inside the asynchronous save. `PreviewController` publishes
/// nothing, so the refresh triggered no redraw — and the redraw that DID
/// happen, synchronously, off the `@Published events` change, read the cache
/// before it was updated. The marker snapped back to its old position and
/// stayed there until an unrelated redraw.
@Suite(.serialized)
@MainActor
struct MarkerDragRefreshTests {

    private func makeState(events: [LoggedEvent]) async throws -> EditorTimelineState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 8.0)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        try await controller.apply(edl: EditDecisionList(), events: events)
        return EditorTimelineState(controller: controller, edl: EditDecisionList(), events: events)
    }

    @Test("A moved marker is drawn at its new position without waiting for the save")
    func moveIsVisibleImmediately() async throws {
        let marker = LoggedEvent(timeSeconds: 2.0, kind: .marker, label: "here")
        let state = try await makeState(events: [marker])
        defer { try? FileManager.default.removeItem(at: state.controller.snittBundle.url) }

        // SYNCHRONOUSLY after the move, with no await between: this is the
        // render pass SwiftUI performs off the `events` change, and the one
        // that used to draw the stale position.
        state.moveMarker(id: marker.id, toOutput: 6.0)
        let drawn = try #require(state.displayState(playhead: 0).markerPoints.first)
        #expect(abs(drawn.timeSeconds - 6.0) < 0.05,
                "drawn at \(drawn.timeSeconds); the move has not reached the lane")
    }

    @Test("A renamed marker relabels the lane immediately too")
    func renameIsVisibleImmediately() async throws {
        // Same cache, same staleness — an edit through the sheet had the same
        // problem, so fixing only the drag would leave half of it.
        let marker = LoggedEvent(timeSeconds: 2.0, kind: .marker, label: "old")
        let state = try await makeState(events: [marker])
        defer { try? FileManager.default.removeItem(at: state.controller.snittBundle.url) }

        state.updateMarker(id: marker.id, label: "new", transcript: nil)
        let drawn = try #require(state.displayState(playhead: 0).markerPoints.first)
        #expect(drawn.label == "new", "lane still says \(drawn.label)")
    }

    @Test("A deleted marker leaves the lane immediately")
    func deleteIsVisibleImmediately() async throws {
        let marker = LoggedEvent(timeSeconds: 2.0, kind: .marker, label: "here")
        let state = try await makeState(events: [marker])
        defer { try? FileManager.default.removeItem(at: state.controller.snittBundle.url) }

        state.deleteMarker(id: marker.id)
        #expect(state.displayState(playhead: 0).markerPoints.isEmpty,
                "the lane still draws a deleted marker")
    }

    @Test("The lane and the chapter panel agree after an edit")
    func laneAndPanelStayInStep() async throws {
        // They read one projection now. Before, the panel derived from `events`
        // and the lane from the controller's cache, so an edit made them
        // disagree for as long as the save took.
        let marker = LoggedEvent(timeSeconds: 2.0, kind: .marker, label: "here")
        let state = try await makeState(events: [marker])
        defer { try? FileManager.default.removeItem(at: state.controller.snittBundle.url) }

        state.moveMarker(id: marker.id, toOutput: 5.0)
        let lane = state.displayState(playhead: 0).markerPoints
        let panel = state.chapters
        #expect(lane.count == panel.count)
        for (point, chapter) in zip(lane, panel) {
            #expect(abs(point.timeSeconds - chapter.outputTime) < 0.001,
                    "lane \(point.timeSeconds) vs panel \(chapter.outputTime)")
        }
    }
}
