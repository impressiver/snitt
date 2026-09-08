import Testing
import Foundation
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// The transcript as an editing surface, at the state layer (D62).
///
/// The recognizer never appears here — it is TCC-gated and the test host holds
/// no grant, which is exactly why `loadTranscript` and `deleteWords` are
/// separate from `beginTranscriptionIfNeeded`. What is asserted is the part
/// that makes D62 an EDITOR: a text deletion becomes cuts on the same EDL,
/// undoable, persisted, and reflected back as strikethrough.
@MainActor
struct TranscriptEditorTests {
    private func makeState(words: [TranscriptWord]) async throws -> (EditorTimelineState, SnittBundle) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 15.0)
        try EditDecisionList.fullRange().write(to: bundle)
        try Transcript(words: words, locale: "en-US").write(to: bundle)
        let built = try await CompositionBuilder.build(bundle: bundle, edl: .fullRange(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: .fullRange(), events: [])
        state.loadTranscript()
        return (state, bundle)
    }

    private static func words() -> [TranscriptWord] {
        [TranscriptWord(text: "and", start: 1.0, duration: 0.3, confidence: 0.9),
         TranscriptWord(text: "look", start: 1.3, duration: 0.3, confidence: 0.9),
         TranscriptWord(text: "here", start: 1.6, duration: 0.3, confidence: 0.9),
         TranscriptWord(text: "done", start: 5.0, duration: 0.4, confidence: 0.9)]
    }

    @Test("An existing transcript.json loads into the editor")
    func existingTranscriptLoads() async throws {
        let (state, bundle) = try await makeState(words: Self.words())
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        #expect(state.transcriptionStatus == .ready)
        #expect(state.transcript?.words.count == 4)
    }

    @Test("Deleting words becomes cuts on the SAME EDL, persisted")
    func deleteWordsBecomesCuts() async throws {
        let (state, bundle) = try await makeState(words: Self.words())
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let transcript = try #require(state.transcript)

        state.deleteWords(ids: Set(transcript.words[1...2].map(\.id)))   // look here
        await state.waitForPendingSave()

        let onDisk = try EditDecisionList.read(from: bundle)
        let cut = try #require(onDisk.cuts.first, "the text deletion never reached edit.json")
        #expect(abs(cut.range.start - 1.3) < 1e-9)
        #expect(abs(cut.range.end - 1.9) < 1e-9)
    }

    @Test("Deleted words strike through, and undo un-strikes them")
    func strikethroughIsDerivedFromTheEDL() async throws {
        // The derived-not-stored property: a word must not "remember" it was
        // deleted, or it would stay struck after the cut's own undo.
        let (state, bundle) = try await makeState(words: Self.words())
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let transcript = try #require(state.transcript)
        let undoManager = UndoManager()
        state.undoManager = undoManager

        state.deleteWords(ids: [transcript.words[3].id])   // done
        await state.waitForPendingSave()
        #expect(state.cutWordIDs == [transcript.words[3].id])

        undoManager.undo()
        await state.waitForPendingSave()
        #expect(state.cutWordIDs.isEmpty, "the word remembered being deleted through an undo")
    }

    @Test("A hand-made timeline cut strikes through the words it silences")
    func timelineCutsStrikeWords() async throws {
        // The two editing surfaces are one model: a drag-cut on the timeline
        // must be visible in the text, exactly as a text deletion is visible as
        // a fold on the timeline.
        let (state, bundle) = try await makeState(words: Self.words())
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let transcript = try #require(state.transcript)

        state.onSelect(Selection(range: TimeRange(start: 4.5, end: 6.0)))
        state.cutSelection()
        await state.waitForPendingSave()

        #expect(state.cutWordIDs == [transcript.words[3].id],
                "the cut over 'done' (5.0-5.4s) did not strike it")
    }

    @Test("Deleting nothing is not an edit")
    func emptyDeletionIsInert() async throws {
        let (state, bundle) = try await makeState(words: Self.words())
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let undoManager = UndoManager()
        state.undoManager = undoManager
        state.deleteWords(ids: [])
        #expect(undoManager.canUndo == false)
        #expect(state.edl.cuts.isEmpty)
    }

    @Test("A bundle without a transcript stays at .none after load")
    func missingTranscriptIsNone() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 2.0)
        let built = try await CompositionBuilder.build(bundle: bundle, edl: .fullRange(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: .fullRange(), events: [])
        state.loadTranscript()
        #expect(state.transcriptionStatus == .none)
        #expect(state.transcript == nil)
    }

    @Test("transcript.json round-trips, and a too-new version is refused")
    func transcriptPersistence() async throws {
        let (_, bundle) = try await makeState(words: Self.words())
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let read = try Transcript.read(from: bundle)
        #expect(read.words.map(\.text) == ["and", "look", "here", "done"])
        #expect(read.locale == "en-US")

        // D60's rule applied to the new sidecar: a version above the current
        // one must refuse loudly, not decode what it recognises.
        let tooNew = #"{"schemaVersion":99,"words":[],"locale":"en-US"}"#
        try Data(tooNew.utf8).write(to: bundle.transcriptURL)
        #expect(throws: TranscriptError.unsupportedSchemaVersion(found: 99, maxSupported: 1)) {
            _ = try Transcript.read(from: bundle)
        }
    }
}

/// Word correction (D62 second slice) — the fix for D68's own "loom is".
@MainActor
struct WordCorrectionTests {
    private func makeState() async throws -> (EditorTimelineState, SnittBundle, Transcript) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 15.0)
        try EditDecisionList.fullRange().write(to: bundle)
        let transcript = Transcript(words: [
            TranscriptWord(text: "loom is", start: 12.81, duration: 0.48, confidence: 0.34),
            TranscriptWord(text: "first", start: 13.4, duration: 0.3, confidence: 0.92),
        ], locale: "en-US")
        try transcript.write(to: bundle)
        let built = try await CompositionBuilder.build(bundle: bundle, edl: .fullRange(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: .fullRange(), events: [])
        state.loadTranscript()
        return (state, bundle, transcript)
    }

    @Test("A correction changes the text, reaches disk, and clears the doubt-dimming")
    func correctionPersists() async throws {
        let (state, bundle, transcript) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.correctWord(id: transcript.words[0].id, text: "Loom is")
        await state.waitForPendingSave()

        let onDisk = try Transcript.read(from: bundle)
        let word = try #require(onDisk.words.first)
        #expect(word.text == "Loom is", "correction never reached transcript.json")
        // Human-verified: the recognizer's 0.34 no longer applies, and the
        // word stops rendering dimmed.
        #expect(word.confidence == 1.0)
    }

    @Test("Correcting text does not move the word in time")
    func timingIsUntouched() async throws {
        // The word WAS said at 12.81s; only the spelling was wrong. Moving it
        // would shift cut spans out from under existing edits.
        let (state, bundle, transcript) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.correctWord(id: transcript.words[0].id, text: "Loom is")
        await state.waitForPendingSave()

        let word = try #require(try Transcript.read(from: bundle).words.first)
        #expect(abs(word.start - 12.81) < 1e-9)
        #expect(abs(word.duration - 0.48) < 1e-9)
    }

    @Test("Undo restores the text AND the recognizer's confidence")
    func correctionUndoes() async throws {
        // Restoring the text but leaving confidence at 1.0 would leave a wrong
        // word rendering as human-verified — worse than never correcting it.
        let (state, bundle, transcript) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let undoManager = UndoManager()
        state.undoManager = undoManager

        state.correctWord(id: transcript.words[0].id, text: "Loom is")
        await state.waitForPendingSave()
        undoManager.undo()
        await state.waitForPendingSave()

        let word = try #require(try Transcript.read(from: bundle).words.first)
        #expect(word.text == "loom is")
        #expect(abs(word.confidence - 0.34) < 1e-9,
                "undo left the wrong word marked human-verified")

        undoManager.redo()
        await state.waitForPendingSave()
        #expect(try Transcript.read(from: bundle).words.first?.text == "Loom is")
    }

    @Test("Empty text is a cancel, not a removal")
    func emptyIsANoOp() async throws {
        // Removing a word from the transcript is not an operation that exists:
        // deleting what was SAID is deleteWords, which cuts footage. A word
        // with no footage behind it would be a lie about the recording.
        let (state, bundle, transcript) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let undoManager = UndoManager()
        state.undoManager = undoManager

        state.correctWord(id: transcript.words[0].id, text: "   ")
        #expect(undoManager.canUndo == false, "an empty commit registered an undo step")
        #expect(state.transcript?.words.first?.text == "loom is")
    }

    @Test("Re-typing the same text is not an edit")
    func identicalTextIsANoOp() async throws {
        let (state, bundle, transcript) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let undoManager = UndoManager()
        state.undoManager = undoManager

        state.correctWord(id: transcript.words[0].id, text: "loom is")
        #expect(undoManager.canUndo == false)
    }

    @Test("A correction and a cut interleave on one undo stack")
    func correctionAndCutShareTheStack() async throws {
        // The whole point of routing everything through one undoManager: the
        // user thinks "undo my last edit", not "undo my last edit of kind X".
        let (state, bundle, transcript) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        let undoManager = UndoManager()
        state.undoManager = undoManager

        state.correctWord(id: transcript.words[0].id, text: "Loom is")
        await state.waitForPendingSave()
        state.deleteWords(ids: [transcript.words[1].id])
        await state.waitForPendingSave()

        undoManager.undo()   // the cut
        await state.waitForPendingSave()
        #expect(state.edl.cuts.isEmpty, "first undo should revert the cut")
        #expect(state.transcript?.words.first?.text == "Loom is", "the correction went too")

        undoManager.undo()   // the correction
        await state.waitForPendingSave()
        #expect(state.transcript?.words.first?.text == "loom is")
    }
}
