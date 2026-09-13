// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittExport
@testable import SnittDocument

/// Captions from the transcript.
///
/// Timing is the whole feature: a caption that is right but late is wrong, and
/// two on screen at once is not a subtle defect — they draw in the same place.
struct SubtitleCuesTests {

    private func words(_ items: [(String, Double, Double)]) -> [TranscriptWord] {
        items.map { TranscriptWord(text: $0.0, start: $0.1, duration: $0.2, confidence: 1) }
    }

    private let whole = [TimeRange(start: 0, end: 60)]

    @Test("Speech becomes a cue that says what was said")
    func spokenWordsBecomeACue() throws {
        let cues = SubtitleCues.cues(
            words: words([("Hello", 1.0, 0.3), ("there", 1.4, 0.4)]), keptRanges: whole)
        let cue = try #require(cues.first)
        #expect(cue.text == "Hello there")
        #expect(abs(cue.start - 1.0) < 1e-9)
    }

    @Test("A pause ends a cue, so two sentences are not one caption")
    func pauseSplitsCues() {
        // Break at the same silence `TranscriptParagraphs` breaks the pane at:
        // the captions and the transcript view should agree about where a
        // sentence ended, or selecting a paragraph highlights the wrong caption.
        let spoken = words([("One", 0.0, 0.3), ("two", 0.4, 0.3),
                            ("three", 3.0, 0.3), ("four", 3.4, 0.3)])
        let cues = SubtitleCues.cues(words: spoken, keptRanges: whole)
        #expect(cues.count == 2, "expected two cues, got \(cues.map(\.text))")
        #expect(cues.first?.text == "One two")
        #expect(cues.last?.text == "three four")
    }

    @Test("A brief word is held long enough to read")
    func shortUtteranceIsHeld() throws {
        // "Yes" takes 0.2s to say. A caption on screen for 0.2s is a flicker,
        // which is worse than no caption because the eye catches motion and
        // finds nothing.
        let cues = SubtitleCues.cues(words: words([("Yes", 5.0, 0.2)]), keptRanges: whole)
        let cue = try #require(cues.first)
        #expect(cue.duration >= SubtitleCues.minimumCueSeconds,
                "held for only \(cue.duration)s")
    }

    @Test("No cue outstays the next one")
    func cuesNeverOverlap() {
        // The failure the hold above creates: a short utterance padded to the
        // minimum runs into the next line when someone speaks quickly. Two
        // captions drawn at once occupy the same place on the frame.
        let quick = words([("Yes", 0.0, 0.2), ("absolutely", 0.8, 0.5),
                           ("right", 1.5, 0.3)])
        let cues = SubtitleCues.cues(words: quick, keptRanges: whole)
        for (a, b) in zip(cues, cues.dropFirst()) {
            #expect(a.end <= b.start,
                    "cue '\(a.text)' ends at \(a.end), after '\(b.text)' starts at \(b.start)")
        }
    }

    @Test("Words inside a cut have no caption")
    func cutWordsAreDropped() {
        // Same rule clicks follow: a word that is not in the output has no
        // output time, and captioning it would put speech over a frame where
        // it was never said.
        let kept = [TimeRange(start: 0, end: 2), TimeRange(start: 8, end: 20)]
        let spoken = words([("before", 1.0, 0.3), ("cut", 5.0, 0.3), ("after", 9.0, 0.3)])
        let cues = SubtitleCues.cues(words: spoken, keptRanges: kept)
        let text = cues.map(\.text).joined(separator: " ")
        #expect(!text.contains("cut"), "a word inside a cut was captioned: \(text)")
        #expect(text.contains("before") && text.contains("after"))
    }

    @Test("Grouping happens in OUTPUT time, so a cut never joins distant words")
    func groupingFollowsTheEdit() {
        // Chosen so the cut is what decides it. In SOURCE time these are 6.2s
        // apart and split; the cut removes 2→8, so in OUTPUT time "before"
        // ends at 1.9 and "after" starts at 2.1 — a 0.2s gap, below the break,
        // so they join. The second is correct: in the exported video they ARE
        // consecutive, because the pause between them was cut out.
        //
        // A first version of this used 1.0 and 8.2, which still leaves a 0.9s
        // gap after mapping — above the 0.6s break — so it split either way
        // and proved nothing about the order of the two steps.
        let kept = [TimeRange(start: 0, end: 2), TimeRange(start: 8, end: 20)]
        let spoken = words([("before", 1.6, 0.3), ("after", 8.1, 0.3)])
        let cues = SubtitleCues.cues(words: spoken, keptRanges: kept)
        #expect(cues.count == 1, "the cut should have joined these: \(cues.map(\.text))")
        #expect(cues.first?.text == "before after")
    }

    @Test("A long sentence wraps to at most two lines")
    func longCuesWrap() {
        let long = (0..<24).map { ("word\($0)", Double($0) * 0.2, 0.15) }
        let cues = SubtitleCues.cues(words: words(long), keptRanges: whole)
        for cue in cues {
            let lines = cue.text.split(separator: "\n")
            #expect(lines.count <= SubtitleCues.maximumLines,
                    "\(lines.count) lines: \(cue.text)")
            // The first lines respect the width; the last may run over rather
            // than drop words, which is the deliberate choice — a truncated
            // caption lies about what was said.
            for line in lines.dropLast() {
                #expect(line.count <= SubtitleCues.maximumCharactersPerLine,
                        "line too wide: \(line)")
            }
        }
    }

    @Test("Nothing is captioned when the whole recording is cut away")
    func noKeptRangesMeansNoCues() {
        #expect(SubtitleCues.cues(words: words([("hello", 1, 0.3)]), keptRanges: []).isEmpty)
    }

    @Test("Lookup finds the caption for a moment, and nothing between them")
    func lookupAtATime() {
        let cues = SubtitleCues.cues(
            words: words([("one", 0.0, 0.3), ("two", 4.0, 0.3)]), keptRanges: whole)
        #expect(SubtitleCues.cue(at: 0.1, in: cues)?.text == "one")
        // The gap between two cues shows nothing — a caption that lingered
        // until the next one would be on screen while nobody is speaking.
        #expect(SubtitleCues.cue(at: 3.5, in: cues) == nil)
        #expect(SubtitleCues.cue(at: 4.1, in: cues)?.text == "two")
    }

    @Test("Reading speed is shared with the sidecar, not a second copy")
    func readingSpeedIsShared() {
        // `WebVTTSubtitles`' own comment says the two readers must move
        // together when either is measured. Two constants named the same
        // thing is how that stops being true.
        #expect(SubtitleCues.wordsPerSecond == WebVTTSubtitles.wordsPerSecond)
        #expect(SubtitleCues.minimumCueSeconds == WebVTTSubtitles.minimumCueSeconds)
        #expect(SubtitleCues.maximumCueSeconds == WebVTTSubtitles.maximumCueSeconds)
    }
}
