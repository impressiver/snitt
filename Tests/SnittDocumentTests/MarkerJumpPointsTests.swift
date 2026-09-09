// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
@testable import SnittDocument

struct MarkerJumpPointsTests {
    @Test("Markers shift by the cuts that precede them")
    func markersShiftByPrecedingCuts() {
        let events = [
            LoggedEvent(timeSeconds: 1.0, kind: .marker, label: "before"),
            LoggedEvent(timeSeconds: 8.0, kind: .marker, label: "after"),
        ]
        // 0-2 kept, 2-5 cut, 5-10 kept.
        let kept = [TimeRange(start: 0, end: 2), TimeRange(start: 5, end: 10)]

        let points = MarkerJumpPoints.compute(events: events, keptRanges: kept)

        #expect(points.count == 2)
        #expect(points[0].timeSeconds == 1.0)
        // 8.0 sits 3s into the second kept range, which begins at preview time
        // 2.0. A fixture with no cut before the marker would make this the
        // identity function and prove nothing.
        #expect(abs(points[1].timeSeconds - 5.0) < 0.001)
    }

    @Test("A marker inside a cut is dropped, not clamped")
    func markerInsideACutIsDropped() {
        let events = [LoggedEvent(timeSeconds: 3.0, kind: .marker, label: "gone")]
        let kept = [TimeRange(start: 0, end: 2), TimeRange(start: 5, end: 10)]
        // Clamping would invent a jump point at a moment the viewer never sees,
        // and several markers in one cut would collapse onto the same instant.
        #expect(MarkerJumpPoints.compute(events: events, keptRanges: kept).isEmpty)
    }

    @Test("Non-marker events are not jump points")
    func onlyMarkersBecomeJumpPoints() {
        let events = [
            LoggedEvent(timeSeconds: 1.0, kind: .click, label: nil),
            LoggedEvent(timeSeconds: 1.5, kind: .marker, label: "kept"),
        ]
        let kept = [TimeRange(start: 0, end: 10)]
        let points = MarkerJumpPoints.compute(events: events, keptRanges: kept)
        // A scrub bar dotted with every click is unusable, and §4.12 scopes jump
        // points to markers.
        #expect(points.count == 1)
        #expect(points[0].label == "kept")
    }

    @Test("An unlabelled marker still gets a usable name")
    func unlabelledMarkersAreNamed() {
        let events = [LoggedEvent(timeSeconds: 1.0, kind: .marker, label: nil)]
        let points = MarkerJumpPoints.compute(
            events: events, keptRanges: [TimeRange(start: 0, end: 10)])
        // `label` is optional on LoggedEvent. A jump point with an empty name is
        // an unclickable blank in the UI.
        #expect(points.count == 1)
        #expect(!points[0].label.isEmpty)
    }

    @Test("An empty label is treated as no label, not as a blank jump point")
func emptyLabelIsNamed() {
    // `label` is optional AND can legitimately be the empty string — the
    // event log stores whatever was passed. A jump point named "" is an
    // unclickable blank in the UI, so "" must fall back the same way nil
    // does. The nil case is covered by `unlabelledMarkersAreNamed`; this is
    // the sibling a `label != nil` check would pass while still shipping a
    // blank.
    let events = [LoggedEvent(timeSeconds: 1.0, kind: .marker, label: "")]
    let points = MarkerJumpPoints.compute(
        events: events, keptRanges: [TimeRange(start: 0, end: 10)])
    #expect(points.count == 1)
    #expect(points[0].label == "Marker")
}

/// M5f Task 6: `JumpPoint` carries the SOURCE marker's own id and
/// transcript, not a freshly minted id or a dropped transcript — a
/// consumer (the timeline's marker track) that needs to drag or edit a
/// SPECIFIC marker has to be able to name it, and a fresh id per call would
/// silently hand back an id that `events.json` cannot look up.
@Test("A JumpPoint carries its source marker's id and transcript")
func jumpPointCarriesSourceIdAndTranscript() {
    let marker = LoggedEvent(timeSeconds: 1.0, kind: .marker, label: "here",
                             transcript: "the narration")
    let points = MarkerJumpPoints.compute(
        events: [marker], keptRanges: [TimeRange(start: 0, end: 10)])
    let point = points.first
    #expect(point?.id == marker.id)
    #expect(point?.transcript == "the narration")
}

@Test("Jump points come back in ascending time order")
    func jumpPointsAreSorted() {
        let events = [
            LoggedEvent(timeSeconds: 8.0, kind: .marker, label: "second"),
            LoggedEvent(timeSeconds: 1.0, kind: .marker, label: "first"),
        ]
        let points = MarkerJumpPoints.compute(
            events: events, keptRanges: [TimeRange(start: 0, end: 10)])
        // events.json is written sorted, so this is load-bearing only for other
        // callers — which is exactly why it needs its own test rather than
        // relying on the file's ordering.
        #expect(points.map(\.label) == ["first", "second"])
    }
}
