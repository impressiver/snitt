// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
@testable import SnittExport
import SnittDocument

private func marker(_ t: Double, _ label: String? = nil) -> LoggedEvent {
    LoggedEvent(timeSeconds: t, kind: .marker, label: label)
}

@Test("A marker exactly at a cut's start boundary is dropped; one exactly at the cut's end boundary is kept")
func markerOnCutBoundary() {
    // Kept ranges from cuts=[4,6) over duration 10: [0,4) and [6,10].
    // MarkerMapping treats a non-final kept range as half-open ([start,
    // end)) and the FINAL kept range as closed ([start, end]) — so a marker
    // landing exactly at the recording's own duration still maps. One
    // consequence: a marker sitting exactly on a cut's START (== a
    // non-final range's end) falls inside no range and is dropped, while
    // one sitting exactly on the cut's END (== the next range's start) is
    // kept and maps to the start of that next segment.
    //
    // Discriminates against an implementation that treats every kept range
    // as closed at both ends ([start, end]), which would keep BOTH boundary
    // markers instead of dropping the first — collapsing a marker that
    // should be dropped onto the same instant as one legitimately kept.
    let keptRanges = [TimeRange(start: 0, end: 4), TimeRange(start: 6, end: 10)]

    let atCutStart = MarkerMapping.map([marker(4, "at cut start")], keptRanges: keptRanges)
    #expect(atCutStart.isEmpty,
            "a marker exactly at the cut's start boundary should be dropped, not kept")

    let atCutEnd = MarkerMapping.map([marker(6, "at cut end")], keptRanges: keptRanges)
    #expect(atCutEnd.count == 1)
    #expect(atCutEnd.first.map { abs($0.timeSeconds - 4.0) < 0.0001 } == true,
            "a marker exactly at the cut's end boundary should map to the start of the next kept segment (4.0s)")
}

@Test("A marker exactly at the recording's own end is kept, not dropped")
func markerAtRecordingEndIsKept() {
    // The final kept range is closed at both ends specifically so a marker
    // at the very last instant of the recording still has somewhere to map
    // to. Discriminates against an implementation that uses the same
    // half-open rule for every range regardless of position, which would
    // drop this marker even though it was never cut.
    let keptRanges = [TimeRange(start: 0, end: 10)]
    let mapped = MarkerMapping.map([marker(10, "at the very end")], keptRanges: keptRanges)
    #expect(mapped.count == 1)
    #expect(mapped.first?.timeSeconds == 10)
}

@Test("Preview and export agree on where a marker lands")
func previewAndExportAgreeOnMarkerTime() {
    let kept = [TimeRange(start: 0, end: 2), TimeRange(start: 5, end: 10)]
    let marker = LoggedEvent(timeSeconds: 8.0, kind: .marker, label: "m")

    let exportTime = MarkerMapping.map([marker], keptRanges: kept).first?.timeSeconds
    let previewTime = MarkerJumpPoints.compute(events: [marker], keptRanges: kept).first?.timeSeconds

    // The two surfaces describing one recording must not disagree. This is
    // the assertion that fails the day someone "improves" one mapper.
    #expect(exportTime != nil)
    #expect(previewTime != nil)
    #expect(abs((exportTime ?? -1) - (previewTime ?? -2)) < 0.0001)
}
