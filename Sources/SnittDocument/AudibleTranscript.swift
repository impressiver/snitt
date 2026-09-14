// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Which transcript words describe sound that is actually in the output.
///
/// **Muting a track hides its words.** A muted track contributes nothing to
/// the exported file, so its speech is not in the recording anyone will watch
/// — and a transcript that still showed it would invite editing against
/// something that is not there: cutting a phrase to remove speech already
/// silenced, or reading a narration nobody will hear as if it were part of the
/// piece.
///
/// Pure, and in `SnittDocument`, because four surfaces ask the same question
/// and must not answer it differently: the reading pane, the timeline's phrase
/// lane, burned-in subtitles at export, and auto-trim's idea of where the
/// talking is.
public enum AudibleTranscript {

    /// `words`, minus every word from a muted track.
    ///
    /// A word whose track has no `TrackState` is KEPT. That is the older
    /// document: transcripts written before narration existed carry no track
    /// at all and decode as `"microphone"`, and a recording may legitimately
    /// have no state for a source it never had. Dropping them would empty the
    /// transcript of exactly the documents that have the most of it.
    public static func audible(_ words: [TranscriptWord],
                               trackStates: [TrackState]) -> [TranscriptWord] {
        let muted = Set(trackStates.filter(\.muted).map(\.track))
        guard !muted.isEmpty else { return words }
        return words.filter { !muted.contains($0.track) }
    }

    /// Whether a word came from narration rather than the recorded microphone.
    ///
    /// Named rather than compared inline at each call site: the transcript
    /// pane, the timeline lane and any future surface all need to tell the two
    /// apart to colour them, and a string literal repeated four times is four
    /// places to mistype it.
    public static func isVoiceover(_ word: TranscriptWord) -> Bool {
        word.track == "voiceover"
    }
}
