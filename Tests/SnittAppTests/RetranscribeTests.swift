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

/// Re-transcribing with better hints (D81), from the editor.
@Suite(.serialized)
@MainActor
struct RetranscribeTests {

    private func makeState(vocabulary: [String]? = nil) async throws -> EditorTimelineState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 2.0)
        try RecordingMetadata(createdAt: Date(), initiator: .human,
                              vocabulary: vocabulary).write(to: bundle)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        return EditorTimelineState(controller: controller, edl: EditDecisionList(), events: [])
    }

    @Test("The field shows what the transcript was actually made with")
    func fieldLoadsStoredVocabulary() async throws {
        // A blank box would invite retyping terms the recording already knows,
        // and would hide that a previous attempt already used some.
        let state = try await makeState(vocabulary: ["KeptRanges", "SCStream"])
        defer { try? FileManager.default.removeItem(at: state.controller.snittBundle.url) }
        state.loadVocabulary()
        #expect(state.vocabularyText == "KeptRanges, SCStream")
    }

    @Test("A recording with no vocabulary shows an empty field, not the word nil")
    func absentVocabularyShowsEmpty() async throws {
        let state = try await makeState(vocabulary: nil)
        defer { try? FileManager.default.removeItem(at: state.controller.snittBundle.url) }
        state.loadVocabulary()
        #expect(state.vocabularyText.isEmpty)
    }

    @Test("Re-transcribing stores the new terms on the recording first")
    func termsArePersistedBeforeTranscribing() async throws {
        // Written BEFORE the recogniser runs, so a re-transcription that is
        // closed or crashes mid-run still leaves the recording knowing what it
        // was asked to expect — and the next attempt starts from it.
        let state = try await makeState(vocabulary: ["Old"])
        let bundle = state.controller.snittBundle
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.vocabularyText = "KeptRanges,  SCStream , KEPTRANGES"
        state.retranscribe()

        let stored = try #require((try RecordingMetadata.read(from: bundle)).vocabulary)
        // Cleaned on the way in: trimmed, de-duplicated case-insensitively,
        // and keeping the spelling that was typed.
        #expect(stored == ["KeptRanges", "SCStream"], "stored \(stored)")
    }

    @Test("Clearing the field clears the recording's vocabulary")
    func emptyFieldClearsStoredTerms() async throws {
        // Otherwise a hint you deliberately removed keeps biasing every future
        // transcription, and nothing on screen says why.
        let state = try await makeState(vocabulary: ["Wrong"])
        let bundle = state.controller.snittBundle
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.vocabularyText = "   "
        state.retranscribe()
        #expect((try RecordingMetadata.read(from: bundle)).vocabulary == nil)
    }

    @Test("Re-transcribing puts the old transcript on the undo stack")
    func retranscribeIsUndoable() async throws {
        // The corrections guarantee. A corrected word is marked only by
        // confidence 1.0, which a confident recognition also produces, so there
        // is no way to keep corrections and replace everything else — undo is
        // the whole answer, and it has to actually work.
        let state = try await makeState()
        defer { try? FileManager.default.removeItem(at: state.controller.snittBundle.url) }
        let undo = UndoManager()
        state.undoManager = undo

        let corrected = Transcript(schemaVersion: 1, words: [
            TranscriptWord(id: UUID(), text: "KeptRanges", start: 0, duration: 0.4, confidence: 1.0)
        ], locale: "en-US")
        state.setTranscriptForTesting(corrected)

        state.retranscribe()
        // The recogniser is TCC-gated and may do nothing here; what must hold
        // regardless is that the previous transcript was registered for undo
        // BEFORE it could be replaced.
        #expect(undo.canUndo, "re-transcribing did not make itself undoable")
    }
}
