// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
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
