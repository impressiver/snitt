// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// What the transcript pane should be showing.
///
/// Separated from the view for the reason `LaunchOpenPrompt` already
/// establishes: SwiftUI renders blank in the headless test host, so a branch
/// chosen inside a `body` is a branch nothing can assert. The decision is the
/// part that can be wrong; the layout is not.
///
/// It earns its keep immediately on one case. `.ready` with an empty transcript
/// used to fall through to the same view as `.ready` with words, which rendered
/// an empty list under a header reading "0 words" — indistinguishable from
/// still working, from a broken transcriber, and from a recording whose speech
/// went somewhere Snitt does not listen.
enum TranscriptPanePresentation: Equatable {
    /// §4.10's rung: offer the Speech grant with a visible cause.
    case permissionPrompt
    case working
    case failed(String)
    /// Transcription ran and heard nothing — say so, and say which track is
    /// listened to.
    case noSpeechFound
    case transcript
    /// Nothing to show and no way to make one; the pane is not offered at all.
    case unavailable

    /// Whether a written line of narration would be VISIBLE if one were added.
    ///
    /// The `+` lives in the accordion's header, which is drawn in every state
    /// — including the ones whose body is a permission prompt or a progress
    /// spinner. Adding a line there would place it, persist it, and show the
    /// author nothing, which is indistinguishable from the button not working.
    ///
    /// `noSpeechFound` is included deliberately: a recording the recogniser
    /// heard nothing in is a good reason to write the narration yourself, and
    /// that state flips to `transcript` the moment the first line lands.
    var acceptsWrittenNarration: Bool {
        self == .transcript || self == .noSpeechFound
    }

    static func decide(status: EditorTimelineState.TranscriptionStatus,
                       hasTranscript: Bool,
                       wordCount: Int) -> TranscriptPanePresentation {
        switch status {
        case .needsPermission: return .permissionPrompt
        case .transcribing: return .working
        case .failed(let message): return .failed(message)
        case .none: return .unavailable
        case .ready:
            // A `.ready` with no transcript object at all is not "no speech" —
            // it is a state that should not occur, and claiming the microphone
            // heard nothing would be an invention. Treated as unavailable so
            // the pane says nothing rather than something untrue.
            guard hasTranscript else { return .unavailable }
            return wordCount == 0 ? .noSpeechFound : .transcript
        }
    }
}
