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
