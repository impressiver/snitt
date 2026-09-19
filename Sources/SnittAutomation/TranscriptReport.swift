// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittDocument

/// What `snitt transcript` returns (D107).
///
/// The reading half of the same gap `InspectReport` names: an agent cannot
/// watch the video, and until now it could not read what was SAID in it
/// either. A recording could be transcribed on device and the agent that made
/// it had no way to see a word of that, let alone put it on the picture.
///
/// LINES rather than the raw word array. `Transcript` stores one row per word
/// with its own start, duration and confidence, and a ten-minute narration is
/// easily a thousand of them, handing that back would spend an agent's whole
/// context on punctuation-free JSON to answer "what does this recording say".
/// `TranscriptParagraphs` already knows where the lines are, from the pauses
/// the speaker themselves left, and the editor's reading pane shows exactly
/// these lines.
public struct TranscriptReport: Codable, Sendable, Equatable {

    /// One line of the transcript: a run of words with no long pause in it.
    public struct Line: Codable, Sendable, Equatable {
        /// SOURCE seconds, measured on the recording, not on the trimmed
        /// output. The same clock `snitt_inspect`'s markers are on and the
        /// same clock `snitt_add_narration` places a line at, so a time read
        /// out of one can be handed straight to the other. A cut above this
        /// line does not move it.
        public var startSeconds: Double
        public var endSeconds: Double
        /// `"microphone"` or `"voiceover"`, the names `TrackState` uses.
        public var track: String
        /// Whether these words were WRITTEN rather than heard.
        ///
        /// Load-bearing, not decorative: `TranscriptWord.isAuthored`'s own doc
        /// comment explains that deleting a word works by cutting the footage
        /// underneath it, which is meaningless for a line with no seconds
        /// behind it. An agent reading a transcript to decide what to remove
        /// must be able to tell the two apart, so a line never mixes them
        /// (see `lines(of:trackStates:)`).
        public var authored: Bool
        /// Whether this line's track survives the edit's mutes.
        ///
        /// Reported rather than filtered. `AudibleTranscript.audible` DROPS
        /// the words of a muted track, and every surface that draws a
        /// transcript uses it, including burned-in captions at export. If
        /// this report silently did the same, an agent would read a
        /// transcript, ask for captions, and get a video missing the lines it
        /// had just read, with nothing anywhere saying why. Saying "this line
        /// is muted" answers that before it happens.
        public var audible: Bool
        public var text: String

        public init(startSeconds: Double, endSeconds: Double, track: String,
                    authored: Bool, audible: Bool, text: String) {
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.track = track
            self.authored = authored
            self.audible = audible
            self.text = text
        }
    }

    public var bundlePath: String
    /// The locale the recogniser ran with, or `nil` when this recording has no
    /// `transcript.json` at all.
    ///
    /// Nil is the distinction that matters and the reason this is not `""`: a
    /// recording nobody transcribed and a recording transcribed to silence are
    /// different facts, and the remedy differs, one wants the recogniser run,
    /// the other wants narration written.
    public var locale: String?
    public var wordCount: Int
    /// How many of `wordCount` were written rather than heard.
    public var authoredWordCount: Int
    /// Whether this recording's edit draws captions at export.
    ///
    /// Here because it is the question that follows immediately from reading a
    /// transcript, and because narration an agent writes is invisible without
    /// it: the words are in the bundle, Snitt does not speak them (D101 is not
    /// built), so captions are the only way they reach a viewer.
    public var captionsEnabled: Bool
    public var lines: [Line]

    public init(bundlePath: String, locale: String?, wordCount: Int,
                authoredWordCount: Int, captionsEnabled: Bool, lines: [Line]) {
        self.bundlePath = bundlePath
        self.locale = locale
        self.wordCount = wordCount
        self.authoredWordCount = authoredWordCount
        self.captionsEnabled = captionsEnabled
        self.lines = lines
    }

    /// `words` as lines, in time order, marked with what each one is.
    ///
    /// Pause-split by `TranscriptParagraphs`, the same lines the editor's
    /// reading pane draws, so a person and an agent describing the same
    /// recording describe the same lines, and then split AGAIN wherever
    /// authorship changes inside one of them.
    ///
    /// That second split is not tidiness. A paragraph is one voice but not
    /// necessarily one origin: narration written at the moment a take was
    /// recorded lands on the same track, inside the same pause window, and the
    /// combined line would then have to claim `authored: true` or
    /// `authored: false` about words that are both. Either answer is a lie
    /// about half the line, and the flag is the one an agent uses to decide
    /// whether deleting a line cuts footage.
    public static func lines(of words: [TranscriptWord],
                             trackStates: [TrackState]) -> [Line] {
        let muted = Set(trackStates.filter(\.muted).map(\.track))
        return TranscriptParagraphs.split(words)
            .flatMap(splitByAuthorship)
            .map { run in
                Line(startSeconds: run[0].start,
                     endSeconds: run.map(\.end).max() ?? run[0].end,
                     track: run[0].track,
                     authored: run[0].isAuthored,
                     audible: !muted.contains(run[0].track),
                     text: run.map(\.text).joined(separator: " "))
            }
    }

    /// One paragraph as runs of words that agree about `isAuthored`.
    ///
    /// Returns the paragraph's words unchanged, in one run, for the ordinary
    /// case where they all agree, which is every recording that has either no
    /// narration or no speech.
    private static func splitByAuthorship(_ paragraph: TranscriptParagraph) -> [[TranscriptWord]] {
        var runs: [[TranscriptWord]] = []
        for word in paragraph.words {
            if var last = runs.last, last[0].isAuthored == word.isAuthored {
                last.append(word)
                runs[runs.count - 1] = last
            } else {
                runs.append([word])
            }
        }
        return runs
    }
}

/// What writing a line of narration did (D107).
///
/// An agent cannot look at the result, so the answer has to carry enough to
/// know whether the line will reach a viewer, which is not the same question
/// as whether it was written.
public struct NarrationSummary: Codable, Sendable, Equatable {
    public var bundlePath: String
    /// How many words the line became.
    ///
    /// `AuthoredNarration.words` splits on whitespace and gives each word an
    /// equal share of reading time, so this is also how the span below was
    /// arrived at rather than a second, independent count.
    public var wordCount: Int
    /// Where the line sits, in SOURCE seconds.
    ///
    /// The end is computed from `SpeechRate.wordsPerSecond`, which is a
    /// reading speed and not a measurement: nothing has spoken these words, so
    /// nothing knows how long they take. D101's synthesiser replaces the guess
    /// with the durations it actually produces.
    public var startSeconds: Double
    public var endSeconds: Double
    /// Words in the transcript afterwards, written and heard together.
    public var totalWordCount: Int
    /// Whether this recording's edit draws captions at export.
    ///
    /// **False is the interesting case and the reason this field exists.**
    /// Snitt does not speak a written line, D101 is queued, not built, so
    /// captions are the only way it reaches a viewer. Writing narration into a
    /// recording that exports without captions succeeds completely and changes
    /// nothing anybody sees, which is precisely the silent no-op §8 forbids.
    /// The frontends say so in the prose they render from this.
    public var captionsEnabled: Bool

    public init(bundlePath: String, wordCount: Int, startSeconds: Double,
                endSeconds: Double, totalWordCount: Int, captionsEnabled: Bool) {
        self.bundlePath = bundlePath
        self.wordCount = wordCount
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.totalWordCount = totalWordCount
        self.captionsEnabled = captionsEnabled
    }
}
