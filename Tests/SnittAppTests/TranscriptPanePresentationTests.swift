// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import AVFoundation
import SwiftUI
import SnittDocument
import SnittExport
@testable import SnittApp

/// What the transcript pane shows, for each state it can be in.
///
/// Asserted on the DECISION rather than the view: SwiftUI renders blank in the
/// headless host, so a branch chosen inside a `body` is a branch nothing can
/// check. Every case below was previously reachable and unasserted.
@MainActor
struct TranscriptPanePresentationTests {

    private func decide(_ status: EditorTimelineState.TranscriptionStatus,
                        hasTranscript: Bool = true,
                        words: Int = 5) -> TranscriptPanePresentation {
        TranscriptPanePresentation.decide(status: status,
                                          hasTranscript: hasTranscript,
                                          wordCount: words)
    }

    @Test("Transcription that heard nothing says so, rather than showing an empty list")
    func emptyTranscriptIsExplained() {
        // The case this type was extracted for. A recording with a microphone
        // track but no speech in it — a silent demo, or a screen recording of
        // a call where every voice arrived as SYSTEM audio, which Snitt records
        // and does not transcribe — used to render an empty list under a header
        // reading "0 words". Silence about the one state a person cannot act on.
        #expect(decide(.ready, words: 0) == .noSpeechFound)
    }

    @Test("A transcript with words is shown")
    func wordsAreShown() {
        // The other side of the same branch. A test for the empty case alone
        // would pass against an implementation that showed "no speech found"
        // for every recording.
        #expect(decide(.ready, words: 1) == .transcript)
        #expect(decide(.ready, words: 500) == .transcript)
    }

    @Test("Ready with no transcript object claims nothing")
    func readyWithoutATranscriptIsNotNoSpeech() {
        // A state that should not occur, and the tempting handling is wrong:
        // saying "no speech found" would assert something about the microphone
        // that was never established. Better to show nothing than to invent a
        // finding.
        #expect(decide(.ready, hasTranscript: false, words: 0) == .unavailable)
    }

    @Test("Each remaining status maps to its own presentation")
    func everyStatusIsDistinct() {
        // Asserted together because they are one requirement — the pane must
        // never conflate two states — and because a mapping that collapsed any
        // pair would still satisfy each case checked alone.
        #expect(decide(.needsPermission) == .permissionPrompt)
        #expect(decide(.transcribing) == .working)
        #expect(decide(.failed("no recognizer")) == .failed("no recognizer"))
        #expect(decide(.none) == .unavailable)
    }

    @Test("A failure carries its reason through, not a generic message")
    func failureKeepsItsReason() {
        // The pane prints this string. A mapping that dropped it would leave
        // "Transcription failed:" with nothing after the colon, which is worse
        // than no message — it looks like the failure itself was empty.
        #expect(decide(.failed("locale unsupported")) == .failed("locale unsupported"))
        #expect(decide(.failed("a")) != .failed("b"))
    }
}


/// Where a written line can actually be typed (the `+` regression).
///
/// **The bug.** `acceptsWrittenNarration` is true for `.transcript` AND
/// `.noSpeechFound` — deliberately, because a recording the recogniser heard
/// nothing in is the best reason to write the narration yourself. But the
/// field it opens was rendered inside `transcriptBody`, one branch of the
/// pane's switch. So in the `.noSpeechFound` state the `+` was enabled,
/// pressing it set `isWritingNarration`, and nothing appeared.
///
/// Two conditions describing one thing, which is the shape worth pinning
/// rather than the instance: the button's gate and the field's placement have
/// to agree. The field is rendered from the pane's body now, and this asserts
/// the pane hosts a text field in every state the button is live in.
@Suite(.serialized)
@MainActor
struct WrittenNarrationReachabilityTests {
    init() { _ = NSApplication.shared }

    private func containsTextField(_ view: NSView) -> Bool {
        if view is NSTextField { return true }
        return view.subviews.contains { containsTextField($0) }
    }

    /// A state parked in one presentation, without going near the recogniser.
    private func state(words: Int) async throws -> EditorTimelineState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 2)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller,
                                        edl: EditDecisionList(), events: [])
        state.transcript = Transcript(
            words: (0..<words).map {
                TranscriptWord(text: "word", start: Double($0) * 0.2, duration: 0.2,
                               confidence: 1.0, track: "microphone")
            },
            locale: "en-US")
        state.transcriptionStatus = .ready
        return state
    }

    private func hostsField(_ state: EditorTimelineState) -> Bool {
        let host = NSHostingView(rootView: TranscriptPane(state: state, playhead: 0))
        let frame = NSRect(x: 0, y: 0, width: 360, height: 480)
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(window) {} }
        return containsTextField(host)
    }

    @Test("A recording with speech can be written into")
    func theTranscriptStateOpensTheField() async throws {
        // The CONTROL, and the reason it is not optional: the bug was that one
        // of these two worked and the other did not, so a test covering only
        // the broken state could be satisfied by breaking both.
        let subject = try await state(words: 3)
        #expect(TranscriptPanePresentation.decide(
            status: subject.transcriptionStatus, hasTranscript: true,
            wordCount: 3) == .transcript)
        subject.beginWritingNarration()
        #expect(hostsField(subject))
    }

    @Test("A recording the recogniser heard nothing in can be written into")
    func theNoSpeechStateOpensTheField() async throws {
        // THE BUG. Verified to fail against the shipped arrangement: with
        // `narrationField` inside `transcriptBody`, this state hosts no text
        // field at all and the `+` is a button that does nothing.
        let subject = try await state(words: 0)
        #expect(TranscriptPanePresentation.decide(
            status: subject.transcriptionStatus, hasTranscript: true,
            wordCount: 0) == .noSpeechFound)
        #expect(TranscriptPanePresentation.noSpeechFound.acceptsWrittenNarration,
                "the + is not offered here, so this test is asserting nothing")
        subject.beginWritingNarration()
        #expect(hostsField(subject), "the + is live and there is nowhere to type")
    }
}
