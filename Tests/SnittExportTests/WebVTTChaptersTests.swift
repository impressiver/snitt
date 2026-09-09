// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
@testable import SnittExport
import SnittDocument

private func marker(_ t: Double, _ label: String?) -> LoggedEvent {
    LoggedEvent(timeSeconds: t, kind: .marker, label: label)
}

@Test("Chapters run from each marker to the next")
func chaptersSpanToTheNextMarker() {
    let vtt = WebVTTChapters.render(
        markers: [marker(0, "repro"), marker(10, "fix")], duration: 30)
    #expect(vtt.hasPrefix("WEBVTT\n"))
    #expect(vtt.contains("00:00:00.000 --> 00:00:10.000"))
    #expect(vtt.contains("repro"))
    #expect(vtt.contains("00:00:10.000 --> 00:00:30.000"))
    #expect(vtt.contains("fix"))
}

@Test("An unlabelled marker still produces a usable cue")
func unlabelledMarkerGetsAName() {
    // A chapter list with a blank entry is worse than one with "Chapter 2" —
    // a reviewer cannot click something that has no name.
    let vtt = WebVTTChapters.render(markers: [marker(5, nil)], duration: 10)
    #expect(vtt.contains("Chapter 1"))
}

@Test("No markers produces a header and nothing else, not an invalid file")
func noMarkersIsStillValidWebVTT() {
    #expect(WebVTTChapters.render(markers: [], duration: 10) == "WEBVTT\n")
}

@Test("Times are formatted as WebVTT demands, with hours and milliseconds")
func timeFormatting() {
    let vtt = WebVTTChapters.render(markers: [marker(3661.5, "late")], duration: 3700)
    #expect(vtt.contains("01:01:01.500"))
}

@Test("A marker past the end is clamped rather than producing a backwards cue")
func markerBeyondDurationIsClamped() {
    // The brief's original assertion here was `!vtt.contains(X) ||
    // vtt.contains(Y)` — true whenever Y appears anywhere in the string,
    // which it does even for a completely backwards cue (the END timestamp
    // still prints "00:00:10.000"). That passes against an implementation
    // that clamps only the low end and leaves the marker's raw start time
    // unclamped, producing a cue that starts AFTER it ends. This version
    // checks the actual cue line instead of substring presence anywhere in
    // the file.
    let vtt = WebVTTChapters.render(markers: [marker(50, "x")], duration: 10)
    #expect(vtt.contains("00:00:10.000 --> 00:00:10.000\nx"),
            "a marker past the end should clamp to a zero-length cue AT the end, not a backwards one: \(vtt)")
    #expect(!vtt.contains("00:00:50.000"), "the raw, unclamped time must not appear at all")
}

@Test("Non-marker events are ignored even if passed in")
func nonMarkerEventsAreIgnored() {
    // A wrong implementation that renders every LoggedEvent (not just
    // .marker kind) would produce a cue for a click or keystroke, which
    // has no label a human authored and shouldn't appear as a chapter.
    let events: [LoggedEvent] = [
        LoggedEvent(timeSeconds: 1, kind: .click, label: nil),
        marker(5, "only this one"),
    ]
    let vtt = WebVTTChapters.render(markers: events, duration: 10)
    #expect(vtt.contains("only this one"))
    // Only one cue block should exist (one "-->").
    #expect(vtt.components(separatedBy: "-->").count == 2)
}
