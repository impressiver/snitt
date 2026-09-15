// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
@testable import SnittApp

/// When the transcript section opens itself.
///
/// "Open it if there is a transcript, leave it closed if there is not" is one
/// sentence and two branches, and the second one is the one that bites: the
/// section is re-evaluated whenever the word count moves, and every edit to
/// the transcript moves it.
struct TranscriptDisclosureTests {

    @Test("A recording with words opens the section")
    func wordsOpenIt() {
        #expect(RailLayout.transcriptOpensItself(wordCount: 34, alreadyDecided: false))
    }

    @Test("A recording with no transcript leaves it closed")
    func noWordsLeaveItClosed() {
        // An empty section is a header promising something that is not there.
        #expect(!RailLayout.transcriptOpensItself(wordCount: 0, alreadyDecided: false))
    }

    @Test("One word is a transcript")
    func oneWordCounts() {
        // The boundary, stated: `> 0` and not `> 1`. A one-word transcript is
        // a strange recording and still a real one, and a rule that hid it
        // would be indistinguishable from transcription having failed.
        #expect(RailLayout.transcriptOpensItself(wordCount: 1, alreadyDecided: false))
    }

    @Test("It only ever has its say ONCE")
    func itDoesNotReopen() {
        // THE BRANCH THAT MATTERS. Deleting a word changes the count, which
        // re-runs this — so without the latch, closing the section and then
        // editing the transcript would spring it open again and the panel
        // would feel like it was fighting back.
        #expect(!RailLayout.transcriptOpensItself(wordCount: 34, alreadyDecided: true))
        #expect(!RailLayout.transcriptOpensItself(wordCount: 0, alreadyDecided: true))
    }

    @Test("A transcript arriving later still opens it")
    func aLateTranscriptStillOpensIt() {
        // The ordering this exists for: `loadTranscript` runs AFTER the editor
        // opens, so at the moment the rail is first built there is usually
        // nothing to decide from. The rule has to survive being asked with
        // zero first and the real count second.
        var decided = false
        #expect(!RailLayout.transcriptOpensItself(wordCount: 0, alreadyDecided: decided))
        // ...still undecided, because nothing happened.
        #expect(RailLayout.transcriptOpensItself(wordCount: 12, alreadyDecided: decided))
        decided = true
        #expect(!RailLayout.transcriptOpensItself(wordCount: 12, alreadyDecided: decided))
    }

    @Test("An empty transcript does not count as having one")
    func anEmptyTranscriptIsNotATranscript() {
        // `noSpeechFound` is a real state — transcription ran and heard
        // nothing. Opening a section to show nobody said anything is worse
        // than leaving it shut, and the pane says so in its own words when
        // somebody opens it.
        #expect(!RailLayout.transcriptOpensItself(wordCount: 0, alreadyDecided: false))
    }
}
