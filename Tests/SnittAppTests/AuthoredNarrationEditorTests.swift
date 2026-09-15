// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AVFoundation
import Foundation
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// Writing narration from the editor (D100), and what deleting it means.
@MainActor
struct AuthoredNarrationEditorTests {

    /// Held as a stored property, and that is not tidiness:
    /// `EditorTimelineState.undoManager` is WEAK, so a manager created inline
    /// at the assignment deallocates before the next line runs and every undo
    /// silently does nothing. Two tests here passed their assertions about
    /// adding and failed their assertions about undoing, for that reason
    /// alone. Swift Testing builds a fresh instance per test, so this is still
    /// one manager per test.
    private let undoManager = UndoManager()

    private func makeState(words: [TranscriptWord] = [],
                           cuts: [Cut] = []) async throws
        -> (EditorTimelineState, SnittBundle) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 8.0)
        var edl = EditDecisionList.fullRange()
        edl.cuts = cuts
        // Off by default, and `subtitleCues` returns nothing without it.
        edl.showSubtitles = true
        try edl.write(to: bundle)
        if !words.isEmpty { try Transcript(words: words, locale: "en-US").write(to: bundle) }

        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: edl, events: [])
        if !words.isEmpty { state.transcript = Transcript(words: words, locale: "en-US") }
        state.undoManager = undoManager
        return (state, bundle)
    }

    private let spoken = [
        TranscriptWord(text: "hello", start: 1.0, duration: 0.4, confidence: 0.9),
        TranscriptWord(text: "there", start: 1.5, duration: 0.4, confidence: 0.9),
    ]

    @Test("A written line lands on the transcript at the playhead")
    func narrationIsPlacedAtThePlayhead() async throws {
        let (state, bundle) = try await makeState(words: spoken)
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        #expect(state.addNarration("and it fails", atOutput: 4.0))
        let added = state.transcript?.words.filter { $0.isAuthored } ?? []
        #expect(added.map(\.text) == ["and", "it", "fails"])
        #expect(added.allSatisfy { $0.track == "voiceover" })
        let first = try #require(added.first)
        // No cuts in this fixture, so output time IS source time.
        #expect(abs(first.start - 4.0) < 0.01, "placed at \(first.start), expected 4.0")
    }

    @Test("It is placed in SOURCE time, so a cut above it does not move it")
    func narrationIsAnchoredInSourceTime() async throws {
        // Output 4.0 with the first two seconds removed is source 6.0. Storing
        // the output time would leave the line drifting every time a cut above
        // it changed — which is why every word in a transcript is source time.
        let (state, bundle) = try await makeState(
            words: spoken, cuts: [Cut(range: TimeRange(start: 0, end: 2))])
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        #expect(state.addNarration("later", atOutput: 4.0))
        let added = try #require(state.transcript?.words.first { $0.isAuthored })
        #expect(abs(added.start - 6.0) < 0.01, "placed at \(added.start), expected source 6.0")
    }

    @Test("It reaches disk")
    func narrationPersists() async throws {
        let (state, bundle) = try await makeState(words: spoken)
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        #expect(state.addNarration("written down", atOutput: 3.0))
        await state.waitForPendingSave()
        let onDisk = try Transcript.read(from: bundle)
        #expect(onDisk.words.filter { $0.isAuthored }.map(\.text) == ["written", "down"])
    }

    @Test("A recording with no transcript can still be given narration")
    func narrationCreatesATranscript() async throws {
        // Writing narration is the one way to get a transcript without running
        // the recogniser, and refusing here would mean a recording with no
        // speech could never be given any.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        #expect(state.transcript == nil)

        #expect(state.addNarration("first words", atOutput: 1.0))
        #expect(state.transcript?.words.map(\.text) == ["first", "words"])
    }

    @Test("Undoing the FIRST line leaves no transcript, not an empty one")
    func undoOfTheFirstLineRemovesTheTranscript() async throws {
        // An empty transcript reads as "the recogniser ran and heard nothing",
        // which is a different and more discouraging claim than "you have not
        // written anything yet".
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        #expect(state.addNarration("undo me", atOutput: 1.0))
        await state.waitForPendingSave()
        undoManager.undo()
        #expect(state.transcript == nil, "an empty transcript was left behind")
    }

    @Test("Undo puts an existing transcript back exactly")
    func undoRestoresTheTranscript() async throws {
        let (state, bundle) = try await makeState(words: spoken)
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        #expect(state.addNarration("temporary", atOutput: 3.0))
        await state.waitForPendingSave()
        undoManager.undo()
        #expect(state.transcript?.words.map(\.text) == ["hello", "there"])
    }

    @Test("A blank line is not added")
    func blankNarrationIsRefused() async throws {
        let (state, bundle) = try await makeState(words: spoken)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        #expect(!state.addNarration("   ", atOutput: 3.0))
        #expect(state.transcript?.words.count == 2)
    }

    @Test("Deleting a WRITTEN line removes it, and cuts no footage")
    func deletingAuthoredWordsDoesNotCutVideo() async throws {
        // THE HAZARD. `deleteWords` removes a word by cutting the footage
        // underneath it, which is right for speech and nonsense for a line
        // with no seconds behind it — it would delete video the user never
        // asked to lose, at a moment they were only using as a bookmark.
        let (state, bundle) = try await makeState(words: spoken)
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        #expect(state.addNarration("remove me", atOutput: 4.0))
        let written = state.transcript?.words.filter { $0.isAuthored } ?? []
        #expect(written.count == 2)

        state.deleteWords(ids: Set(written.map(\.id)))
        #expect(state.edl.cuts.isEmpty, "deleting a written line cut the video")
        #expect(state.transcript?.words.map(\.text) == ["hello", "there"],
                "the written line was not removed")
    }

    @Test("Deleting SPOKEN words still cuts the footage")
    func deletingSpokenWordsStillCuts() async throws {
        // The behaviour that must survive: the way to unsay something somebody
        // said is to remove the seconds in which they said it.
        let (state, bundle) = try await makeState(words: spoken)
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.deleteWords(ids: Set(spoken.map(\.id)))
        #expect(!state.edl.cuts.isEmpty, "deleting speech cut nothing")
        // And the words stay in the transcript, struck through — the EDL is
        // the single record of what is removed.
        #expect(state.transcript?.words.count == 2)
    }

    @Test("A mixed selection does each to its own words")
    func mixedSelectionDoesBoth() async throws {
        // Dragging across a written line and a spoken one is an ordinary thing
        // to do and has an obvious meaning; refusing it would be the surprise.
        let (state, bundle) = try await makeState(words: spoken)
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        #expect(state.addNarration("mine", atOutput: 4.0))
        let written = state.transcript?.words.filter { $0.isAuthored } ?? []
        let everything = Set((written + spoken).map(\.id))

        state.deleteWords(ids: everything)
        #expect(!state.edl.cuts.isEmpty, "the spoken half cut nothing")
        #expect(state.transcript?.words.contains { $0.isAuthored } == false,
                "the written half survived")
        #expect(state.transcript?.words.count == 2, "the spoken words were removed too")
    }

    @Test("A written line shows up as narration everywhere else")
    func narrationCountsAsASecondVoice() async throws {
        // The payoff before synthesis exists: the line is captioned, gets its
        // own row, and turns on the pane's lane rules — all from the same
        // `track` the recorded voiceover uses.
        let (state, bundle) = try await makeState(words: spoken)
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        #expect(state.addNarration("narrated over the top", atOutput: 1.2))
        #expect(state.hasNarration)
        let rows = TranscriptParagraphs.split(state.audibleWords)
        #expect(Set(rows.map(\.track)) == ["microphone", "voiceover"])
        #expect(rows.allSatisfy { Set($0.words.map(\.track)).count == 1 })
        #expect(!state.subtitleCues.filter { $0.track == "voiceover" }.isEmpty,
                "a written line produced no caption")
    }
}
