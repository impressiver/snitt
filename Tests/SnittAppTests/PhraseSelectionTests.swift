// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
@testable import SnittApp
@testable import SnittDocument

/// Clicking a phrase chip in the transcript lane, through the WHOLE gesture.
///
/// Reported from the app: the playhead "jumps to start of phrase, then it
/// immediately jumps to mouse position", and the phrase itself could not be
/// selected. Both are one defect. `handlePhraseClick` resolved the press
/// during `mouseDown` and returned — but never CLAIMED the gesture, so the
/// trailing `mouseUp` found nothing active, took the plain-click path, called
/// `onSelect(nil)` and scrubbed to the pointer.
///
/// `TranscriptLaneTests` drives `handlePhraseClickForTesting` and stops there,
/// which is exactly the shape that cannot see this — the same blind spot the
/// fold branch had, recorded in `mouseDown`'s own comment: "The existing test
/// drove `mouseDown` with `clickCount: 2` and stopped there, so it asserted
/// the selection that IS made and never the `mouseUp` that took it away."
/// Every test here therefore drives BOTH halves.
@Suite(.serialized)
@MainActor
struct PhraseSelectionTests {
    init() { _ = NSApplication.shared }

    private let width = 600.0
    private let tall = 180.0

    private static let words: [TranscriptWord] = {
        var out: [TranscriptWord] = []
        for (index, text) in ["the", "bug", "is", "in", "the", "lookup"].enumerated() {
            out.append(TranscriptWord(text: text, start: Double(index) * 0.4,
                                      duration: 0.3, confidence: 0.9))
        }
        for (index, text) in ["one", "tick", "fixes", "it"].enumerated() {
            out.append(TranscriptWord(text: text, start: 10 + Double(index) * 0.4,
                                      duration: 0.3, confidence: 0.9))
        }
        return out
    }()

    private func makeView() -> TimelineView {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: tall))
        view.update(duration: 20, cuts: [], markerPoints: [], playhead: 0)
        view.update(phrases: TranscriptPhrases.phrases(from: Self.words))
        return view
    }

    private func phrasePoint(in view: TimelineView) -> NSPoint {
        let bands = TimelineTrackLayout.bands(in: view.bounds, markerHeight: 24,
                                              audioTracks: [], hasTranscript: true)
        return NSPoint(x: 40, y: bands.transcript.midY)
    }

    @Test("A click on a phrase leaves the playhead AT the phrase, not at the pointer")
    func mouseUpDoesNotReScrubToThePointer() throws {
        let view = makeView()
        var scrubs: [Double] = []
        view.onScrub = { scrubs.append($0) }
        let point = phrasePoint(in: view)
        let phrase = try #require(view.phraseHitForTesting(at: point))

        view.mouseDown(with: .synthetic(at: point, in: view))
        view.mouseUp(with: .synthetic(at: point, in: view))

        // The count is the assertion. A second scrub is the defect, and its
        // VALUE is close enough to the first that "the last scrub was roughly
        // the phrase start" would pass against the broken code — the chip sits
        // at that x, so the pointer is near the phrase by construction.
        #expect(scrubs.count == 1,
                "the gesture scrubbed \(scrubs.count) times: \(scrubs)")
        #expect(scrubs.first == phrase.start)
    }

    @Test("A click on a phrase SELECTS the utterance, and the selection survives mouseUp")
    func phraseClickSelectsTheUtterance() throws {
        let view = makeView()
        var reported: [Selection?] = []
        view.onSelect = { reported.append($0) }
        let point = phrasePoint(in: view)
        let phrase = try #require(view.phraseHitForTesting(at: point))

        view.mouseDown(with: .synthetic(at: point, in: view))
        view.mouseUp(with: .synthetic(at: point, in: view))

        // The LAST thing reported is what the editor is left holding. Asserting
        // only that a selection was made at some point passes against the
        // broken code, which made one and then cleared it a moment later.
        #expect(reported.last as? Selection != nil,
                "the selection was reported and then cleared: \(reported)")
        let selection = try #require(reported.last ?? nil)
        #expect(selection.range.start == phrase.start)
        #expect(selection.range.end == phrase.end)
        #expect(reported.last(where: { $0 == nil }) == nil,
                "something cleared the selection during the gesture")
    }

    @Test("The selected span is the utterance, so the highlight shows what Delete removes")
    func selectionSpansTheWholeUtterance() throws {
        // "Reflecting what would actually get cut": the range handed to
        // `onSelect` is the same `TimeRange` `cutSelection` turns into a `Cut`,
        // so the highlight and the edit cannot disagree. A start-only
        // selection — a zero-width range at the phrase's start — would satisfy
        // a "something was selected" check and cut nothing.
        let view = makeView()
        var selection: Selection?
        view.onSelect = { selection = $0 }
        let point = phrasePoint(in: view)
        let phrase = try #require(view.phraseHitForTesting(at: point))

        view.mouseDown(with: .synthetic(at: point, in: view))
        view.mouseUp(with: .synthetic(at: point, in: view))

        let range = try #require(selection?.range)
        #expect(range.end > range.start, "a zero-width selection cuts nothing")
        #expect(range.end - range.start == phrase.end - phrase.start)
        // And it covers every word in the phrase, not just the first.
        let lastWordEnd = try #require(phrase.words.last.map { $0.start + $0.duration })
        #expect(range.end >= lastWordEnd - 1e-9,
                "the selection stops at \(range.end), before the phrase's last word ends at \(lastWordEnd)")
    }

    @Test("A click away from the lane still scrubs and still clears the selection")
    func ordinaryClicksAreUnchanged() {
        // The other side of the claim. A phrase click that claimed EVERY
        // gesture would break scrubbing on the rest of the timeline, and the
        // flag has to be cleared by the next press rather than latching.
        let view = makeView()
        var scrubs: [Double] = []
        var reported: [Selection?] = []
        view.onScrub = { scrubs.append($0) }
        view.onSelect = { reported.append($0) }

        let phrase = phrasePoint(in: view)
        view.mouseDown(with: .synthetic(at: phrase, in: view))
        view.mouseUp(with: .synthetic(at: phrase, in: view))

        // Now somewhere with no chip under it, in the VIDEO band. Both
        // coordinates matter and the first draft got both wrong: x=300 is
        // 10s into a 20s/600pt timeline, which is exactly where the second
        // phrase starts, and this view is FLIPPED, so a large y is the
        // transcript lane rather than away from it.
        let bands = TimelineTrackLayout.bands(in: view.bounds, markerHeight: 24,
                                              audioTracks: [], hasTranscript: true)
        let elsewhere = NSPoint(x: 180, y: bands.video.midY)
        #expect(view.phraseHitForTesting(at: elsewhere) == nil, "fixture: that point IS a phrase")
        view.mouseDown(with: .synthetic(at: elsewhere, in: view))
        view.mouseUp(with: .synthetic(at: elsewhere, in: view))

        // Three, not two: an ORDINARY click scrubs on the press and again on
        // the release, both to the same x — harmless, long-standing, and not
        // what was reported. The phrase click contributes exactly one. Stated
        // as the total so this test also pins that the phrase path did not
        // quietly acquire the second scrub.
        #expect(scrubs.count == 3, "the second click did not scrub twice: \(scrubs)")
        #expect(scrubs.dropFirst().allSatisfy { abs($0 - scrubs[1]) < 1e-9 },
                "the ordinary click's two scrubs disagree: \(scrubs)")
        #expect(reported.last as? Selection == nil,
                "a plain click must clear the phrase selection, and left \(String(describing: reported.last))")
    }
}
