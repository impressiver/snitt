// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
import AVFoundation
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// A crop made in the editor persists and undoes, like every other edit (D46).
///
/// These assert the MODEL and the file, not the overlay view. `CropDragOverlay`
/// is a SwiftUI gesture surface a runtime test cannot drive; all of its
/// arithmetic lives in `CropGeometry`, which is pure and tested separately.
/// Testing the state here and the geometry there covers everything except the
/// two-line hookup between them.
@MainActor
struct EditorCropTests {
    private func makeState() async throws -> (EditorTimelineState, SnittBundle) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 3.0)
        try EditDecisionList.fullRange().write(to: bundle)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        return (EditorTimelineState(controller: controller, edl: EditDecisionList(), events: []), bundle)
    }

    @Test("A crop reaches edit.json, not just memory")
    func cropPersists() async throws {
        // D46's whole point: an edit that only exists in memory is discarded on
        // window close, which is the defect six reviewers independently found
        // in the original trim path.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.applyCrop(CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        await state.waitForPendingSave()

        let onDisk = try EditDecisionList.read(from: bundle)
        let crop = try #require(onDisk.crop, "crop never reached edit.json")
        #expect(abs(crop.x - 0.25) < 1e-9)
        #expect(abs(crop.width - 0.5) < 1e-9)
    }

    @Test("A second crop composes against the source, not the visible frame")
    func secondCropComposes() async throws {
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.applyCrop(CropRect(x: 0.5, y: 0, width: 0.5, height: 1))
        await state.waitForPendingSave()
        // The preview now shows the right half. Cropping its right half again
        // must land on the source's last quarter — an implementation that
        // simply overwrote would leave x at 0.5.
        state.applyCrop(CropRect(x: 0.5, y: 0, width: 0.5, height: 1))
        await state.waitForPendingSave()

        let crop = try #require(state.edl.crop)
        #expect(abs(crop.x - 0.75) < 1e-9, "second crop overwrote instead of composing")
        #expect(abs(crop.width - 0.25) < 1e-9)
    }

    @Test("Undo restores the previous crop, and redo reapplies it")
    func cropUndoes() async throws {
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let undoManager = UndoManager()
        state.undoManager = undoManager

        state.applyCrop(CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        await state.waitForPendingSave()
        #expect(state.edl.crop != nil)

        undoManager.undo()
        await state.waitForPendingSave()
        #expect(state.edl.crop == nil, "undo did not remove the crop")

        undoManager.redo()
        await state.waitForPendingSave()
        #expect(state.edl.crop != nil, "redo did not reapply the crop")
    }

    @Test("Reset removes the crop and persists that removal")
    func resetCropPersists() async throws {
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.applyCrop(CropRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5))
        await state.waitForPendingSave()
        state.resetCrop()
        await state.waitForPendingSave()

        #expect(try EditDecisionList.read(from: bundle).crop == nil,
                "reset left a crop on disk")
    }

    @Test("Reset with no crop set does not push an undo step")
    func resetWithoutCropIsNotAnEdit() async throws {
        // Otherwise ⌘Z after a stray Reset Crop click would undo the user's
        // last REAL edit while appearing to do nothing.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let undoManager = UndoManager()
        state.undoManager = undoManager

        state.resetCrop()
        #expect(undoManager.canUndo == false, "an empty reset registered an undo step")
    }
}
