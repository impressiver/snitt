// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AVFoundation
import Foundation
import SwiftUI
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// The `+` that writes a line of narration, and the field it opens.
///
/// Reported as "the + doesn't do anything", and it did not: the button is
/// drawn in the accordion's HEADER, so `TranscriptPane.addButton` is produced
/// from a pane value that is never itself installed as a view — only the
/// `Button` it returns is. Writing `@State` from there goes to storage nothing
/// observes. The action ran on every click and changed nothing.
///
/// The fix is where the state lives, and these tests exist because the old
/// arrangement could not have them: view-local `@State` has no seam, and that
/// untestability IS the defect. `MarkerPane.addButton` has always worked for
/// the same reason it is now testable — it calls a method on this object.
@MainActor
struct WritingNarrationTests {

    private let undoManager = UndoManager()

    private func makeState() async throws -> (EditorTimelineState, SnittBundle) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 8.0)
        var edl = EditDecisionList.fullRange()
        edl.showSubtitles = true
        try edl.write(to: bundle)
        let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: edl, events: [])
        state.undoManager = undoManager
        return (state, bundle)
    }

    @Test("Pressing + opens the field")
    func beginOpensTheField() async throws {
        // The whole of the reported bug, in one assertion. It could not be
        // written before, because the flag lived in a view that nothing
        // installed.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        #expect(!state.isWritingNarration)
        state.beginWritingNarration()
        #expect(state.isWritingNarration)
    }

    @Test("It opens empty, even after an abandoned draft")
    func reopeningStartsEmpty() async throws {
        // A field showing yesterday's half-typed line is worse than one that
        // starts blank — and it is the state you would get from flipping a
        // flag rather than calling through a method.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        state.beginWritingNarration()
        state.narrationDraft = "half a thought"
        state.cancelWritingNarration()
        #expect(!state.isWritingNarration)
        #expect(state.narrationDraft.isEmpty)

        state.beginWritingNarration()
        #expect(state.narrationDraft.isEmpty)
    }

    @Test("Committing writes the line and closes the field")
    func commitWritesAndCloses() async throws {
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        state.beginWritingNarration()
        state.narrationDraft = "and here it fails"

        #expect(state.commitWrittenNarration(atOutput: 3.0))
        #expect(!state.isWritingNarration)
        #expect(state.narrationDraft.isEmpty)
        #expect(state.transcript?.words.map(\.text) == ["and", "here", "it", "fails"])
    }

    @Test("An empty draft leaves the field open and the text alone")
    func emptyDraftKeepsTheFieldOpen() async throws {
        // Swallowing the text would be indistinguishable from the bug being
        // fixed here: press return, nothing happens, no explanation.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        state.beginWritingNarration()
        state.narrationDraft = "   "

        #expect(!state.commitWrittenNarration(atOutput: 3.0))
        #expect(state.isWritingNarration, "the field closed on a line it did not add")
        #expect(state.narrationDraft == "   ", "the text was thrown away")
        #expect(state.transcript == nil)
    }

    @Test("Cancelling adds nothing")
    func cancelAddsNothing() async throws {
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        state.beginWritingNarration()
        state.narrationDraft = "never mind"
        state.cancelWritingNarration()
        #expect(state.transcript == nil)
    }

    @Test("The field is what the flag actually draws")
    func theFlagDrawsTheField() async throws {
        // Rendered, because "the flag is true" and "there is somewhere to type"
        // are different claims — and the gap between them is exactly where the
        // reported bug lived.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        state.setTranscriptForTesting(
            Transcript(words: [TranscriptWord(text: "hello", start: 1, duration: 0.3,
                                              confidence: 1)],
                       locale: "en-US"))

        func height(writing: Bool) throws -> Int {
            state.isWritingNarration = writing
            let renderer = ImageRenderer(
                content: TranscriptPane(state: state, playhead: 1.0).frame(width: 260))
            renderer.scale = 1
            let image = try #require(renderer.nsImage)
            return Int(image.size.height)
        }

        let closed = try height(writing: false)
        let open = try height(writing: true)
        #expect(open > closed,
                "the pane is \(open)pt open and \(closed)pt closed: the flag draws nothing")
    }
}
