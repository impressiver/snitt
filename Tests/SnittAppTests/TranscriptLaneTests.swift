// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp
@testable import SnittDocument

/// The transcript lane on the timeline (D89, phrase tier).
@MainActor
struct TranscriptLaneTests {
    private let width = 800.0
    private let duration = 20.0
    /// Tall enough for marks + folds + a usable filmstrip + the transcript.
    private let tall = 180.0

    private static let words: [TranscriptWord] = {
        var out: [TranscriptWord] = []
        for (index, text) in ["the", "bug", "is", "in", "the", "word", "lookup"].enumerated() {
            out.append(TranscriptWord(text: text, start: Double(index) * 0.4,
                                      duration: 0.3, confidence: 0.9))
        }
        for (index, text) in ["one", "tick", "fixes", "it"].enumerated() {
            out.append(TranscriptWord(text: text, start: 10 + Double(index) * 0.4,
                                      duration: 0.3, confidence: 0.9))
        }
        return out
    }()

    private func makeView(height: Double, withPhrases: Bool = true) -> TimelineView {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.update(duration: duration, cuts: [], markerPoints: [], playhead: 0)
        if withPhrases {
            view.update(phrases: TranscriptPhrases.phrases(from: Self.words))
        }
        return view
    }

    @Test("A recording with no transcript gets no lane")
    func noTranscriptNoLane() {
        // A band reserved for content that does not exist is a dead strip, and
        // it costs the filmstrip the height it would have had.
        let bands = TimelineTrackLayout.bands(in: NSRect(x: 0, y: 0, width: width, height: tall),
                                              markerHeight: 24, audioTracks: ["microphone"],
                                              hasTranscript: false)
        #expect(abs(bands.transcript.height) < 0.001)
    }

    @Test("The lane sits at the bottom and takes its height from nobody's floor")
    func laneSitsAtTheBottom() {
        let bands = TimelineTrackLayout.bands(in: NSRect(x: 0, y: 0, width: width, height: tall),
                                              markerHeight: 24, audioTracks: ["microphone"],
                                              hasTranscript: true)
        #expect(abs(bands.transcript.maxY - tall) < 0.001)
        #expect(bands.video.height >= TimelineLaneBudget.minimumVideoHeight)
        #expect(bands.audio.last!.rect.maxY <= bands.transcript.minY + 0.001)
    }

    @Test("The lane yields rather than squeezing the filmstrip under its floor")
    func laneYieldsToTheFilmstrip() {
        // DERIVED, not a fixed 80. This test used to pass at 80pt because the
        // fold lane took 24 of them; removing that lane (rev 5, W11) freed
        // exactly enough room for the transcript to fit at that height, and
        // the test started failing for a reason that was the change working
        // rather than breaking. A height computed from the constants moves
        // with them instead of going stale the next time the stack changes.
        let justTooShort = TimelineLaneBudget.minimumTargetHeight        // marks
            + TimelineLaneBudget.transcriptLaneHeight
            + TimelineLaneBudget.minimumVideoHeight - 1
        let bands = TimelineTrackLayout.bands(
            in: NSRect(x: 0, y: 0, width: width, height: justTooShort),
            markerHeight: TimelineLaneBudget.minimumTargetHeight,
            audioTracks: ["microphone"], hasTranscript: true)
        #expect(abs(bands.transcript.height) < 0.001,
                "the transcript lane took room the filmstrip needed")
        #expect(bands.video.height > 0)
    }

    @Test("Clicking a chip seeks to the phrase's START, not to the click")
    func clickingAChipSeeksToThePhrase() {
        // The whole difference the lane offers over scrubbing. A click that
        // fell through to scrub would land the playhead NEAR the phrase, which
        // is what the timeline already did before the lane existed.
        let view = makeView(height: tall)
        var scrubbed: Double?
        view.onScrub = { scrubbed = $0 }
        let bands = TimelineTrackLayout.bands(in: view.bounds, markerHeight: 24,
                                              audioTracks: [], hasTranscript: true)
        let point = NSPoint(x: 40, y: bands.transcript.midY)
        let phrase = try! #require(view.phraseHitForTesting(at: point))
        // Driven in VIEW coordinates rather than through a synthetic event: on
        // a windowless view AppKit's window-to-view conversion is what the
        // event path exercises, and that is not the behaviour under test —
        // the same lesson the fold gate taught one lane over.
        #expect(view.handlePhraseClickForTesting(at: point))
        #expect(scrubbed == phrase.start)
        #expect(scrubbed != 1.0, "the click scrubbed to its own x instead of the phrase")
    }

    @Test("A hit outside the lane is not a phrase")
    func aboveTheLaneIsNotAPhrase() {
        // Y-gated exactly as folds are. Without it a click anywhere at a
        // phrase's x would seek to the phrase instead of scrubbing.
        let view = makeView(height: tall)
        #expect(view.phraseHitForTesting(at: NSPoint(x: 40, y: 10)) == nil)
        #expect(view.phraseHitForTesting(at: NSPoint(x: 40, y: 90)) == nil)
    }

    @Test("A gap between phrases is not a phrase")
    func silenceIsNotAPhrase() {
        // The words run 0-2.8s and 10-11.6s. Halfway through the silence
        // between them there is nothing to jump to, and a chip that claimed
        // that span would jump the playhead somewhere nothing was said.
        let view = makeView(height: tall)
        let bands = TimelineTrackLayout.bands(in: view.bounds, markerHeight: 24,
                                              audioTracks: [], hasTranscript: true)
        let midSilenceX = width * (6.0 / duration)
        #expect(view.phraseHitForTesting(
            at: NSPoint(x: midSilenceX, y: bands.transcript.midY)) == nil)
    }
}
