// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittAutomation
import SnittDocument

/// D107's read half: a transcript an agent can act on.
@Suite
struct TranscriptReportTests {

    private func word(_ text: String, at start: Double, duration: Double = 0.3,
                      track: String = "microphone",
                      authored: Bool = false) -> TranscriptWord {
        TranscriptWord(text: text, start: start, duration: duration,
                       confidence: 1.0, track: track, isAuthored: authored)
    }

    @Test("A pause becomes a line break, and the text reads back")
    func pausesSplitLines() {
        // `TranscriptParagraphs.breakSeconds` is 0.6, so the gap below breaks.
        let lines = TranscriptReport.lines(
            of: [word("the", at: 0), word("tests", at: 0.3),
                 word("are", at: 2.0), word("green", at: 2.3)],
            trackStates: [])
        #expect(lines.count == 2)
        #expect(lines.first?.text == "the tests")
        #expect(lines.last?.text == "are green")
        #expect(lines.first?.startSeconds == 0)
        // Within a millisecond: the end is a sum of Doubles, and pinning it to
        // an exact literal would be a test of IEEE754 rather than of lines.
        #expect(abs((lines.last?.endSeconds ?? 0) - 2.6) < 0.001)
    }

    @Test("A muted track's line is REPORTED as muted, never dropped")
    func mutedLinesAreMarkedRatherThanRemoved() {
        // DISCRIMINATES AGAINST: running the words through
        // `AudibleTranscript.audible` first, which is what every other surface
        // that draws a transcript does and is the obvious thing to copy here.
        // It DROPS a muted track's words. An agent would then read a
        // transcript, see nothing from the microphone, and conclude the
        // recogniser failed, when the truth is that somebody muted the track
        // and the remedy is a mute, not a re-transcription. With a filter in
        // place this test sees one line instead of two and fails.
        let lines = TranscriptReport.lines(
            of: [word("heard", at: 0),
                 word("written", at: 5, track: "voiceover", authored: true)],
            trackStates: [TrackState(track: "microphone", muted: true)])
        #expect(lines.count == 2)
        #expect(lines.first(where: { $0.track == "microphone" })?.audible == false)
        #expect(lines.first(where: { $0.track == "voiceover" })?.audible == true)
    }

    @Test("A line never mixes a written word with a heard one")
    func authorshipNeverMixesInsideALine() {
        // DISCRIMINATES AGAINST: returning `TranscriptParagraphs.split` as-is.
        // A paragraph is one VOICE, not one origin: narration written onto the
        // same track, inside the same 0.6s pause window, joins the paragraph
        // beside speech the recogniser heard. The combined line then has to
        // claim `authored: true` or `authored: false` about words that are
        // both, and `authored` is the flag that decides whether deleting a
        // line cuts footage (`TranscriptWord.isAuthored`). Without the second
        // split this returns one line and fails.
        let lines = TranscriptReport.lines(
            of: [word("heard", at: 0.0, track: "microphone"),
                 word("written", at: 0.4, track: "microphone", authored: true)],
            trackStates: [])
        #expect(lines.count == 2)
        #expect(lines.first?.authored == false)
        #expect(lines.first?.text == "heard")
        #expect(lines.last?.authored == true)
        #expect(lines.last?.text == "written")
    }

    @Test("An ordinary one-voice transcript still comes back as whole lines")
    func theCommonCaseIsNotShredded() {
        // The control for the split above: splitting on every word would also
        // pass `authorshipNeverMixesInsideALine`, and would turn every
        // transcript into one line per word.
        let lines = TranscriptReport.lines(
            of: (0..<6).map { word("w\($0)", at: Double($0) * 0.3) },
            trackStates: [])
        #expect(lines.count == 1)
        #expect(lines.first?.text == "w0 w1 w2 w3 w4 w5")
    }

    @Test("An empty transcript yields no lines rather than one empty one")
    func noWordsYieldNoLines() {
        #expect(TranscriptReport.lines(of: [], trackStates: []).isEmpty)
    }

    @Test("The report round-trips over the wire")
    func reportEncodesAndDecodes() throws {
        // `structuredContent` and the CLI's `emit` both hand this to a caller
        // as JSON; a field that does not survive a round trip is a field an
        // agent never sees.
        let report = TranscriptReport(
            bundlePath: "/tmp/x.snitt", locale: "en-US", wordCount: 2,
            authoredWordCount: 1, captionsEnabled: false,
            lines: TranscriptReport.lines(
                of: [word("hello", at: 0),
                     word("there", at: 9, track: "voiceover", authored: true)],
                trackStates: []))
        let back = try JSONDecoder().decode(
            TranscriptReport.self, from: JSONEncoder().encode(report))
        #expect(back == report)
        #expect(back.locale == "en-US")
    }

    @Test("A recording with no transcript is not the same as one with no words")
    func nilLocaleIsDistinctFromEmpty() {
        // DISCRIMINATES AGAINST: `locale: String` defaulting to "". The two
        // states want different next moves, run the recogniser, or write a
        // line, and an empty string makes them identical to a caller.
        let none = TranscriptReport(bundlePath: "/tmp/x.snitt", locale: nil,
                                    wordCount: 0, authoredWordCount: 0,
                                    captionsEnabled: false, lines: [])
        let silent = TranscriptReport(bundlePath: "/tmp/x.snitt", locale: "en-US",
                                      wordCount: 0, authoredWordCount: 0,
                                      captionsEnabled: false, lines: [])
        #expect(none != silent)
        #expect(none.locale == nil)
    }
}
