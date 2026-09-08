import Testing
import Foundation
@testable import SnittDocument

/// The marker TRACK keeps markers whose instant was cut; the jump LIST drops
/// them. Two jobs, two functions.
///
/// `MarkerJumpPoints.compute` drops them deliberately — a jump list exists to
/// seek somewhere, and clamping would offer to seek to a moment the viewer
/// never sees. The timeline reused that list to draw its marker track, so a
/// marker inside a cut disappeared from the UI while remaining in
/// `events.json`: invisible, unmovable, undeletable, and silently back the
/// moment the cut was removed.
@Suite
struct MarkerTrackPointsTests {
    private let kept = [TimeRange(start: 0, end: 2), TimeRange(start: 5, end: 10)]

    @Test("A marker inside a cut survives, at the fold")
    func markerInsideACutIsKept() throws {
        let events = [LoggedEvent(timeSeconds: 3.0, kind: .marker, label: "inside")]
        let points = MarkerTrackPoints.compute(events: events, keptRanges: kept)
        let point = try #require(points.first, "the marker vanished — the original defect")
        #expect(point.isInsideCut)
        // The cut spans source 2...5, which collapses to output 2.0.
        #expect(abs(point.timeSeconds - 2.0) < 0.001)
    }

    @Test("The jump list still drops it — the two must not converge")
    func jumpListStillDrops() {
        // If this ever starts returning the marker, the jump list has silently
        // adopted the track's behaviour and will offer to seek to a moment the
        // viewer never sees.
        let events = [LoggedEvent(timeSeconds: 3.0, kind: .marker, label: "inside")]
        #expect(MarkerJumpPoints.compute(events: events, keptRanges: kept).isEmpty)
    }

    @Test("A marker outside every cut is not flagged, and both agree on it")
    func markerOutsideACutIsUnflagged() throws {
        let events = [LoggedEvent(timeSeconds: 6.0, kind: .marker, label: "visible")]
        let track = try #require(MarkerTrackPoints.compute(events: events, keptRanges: kept).first)
        let jump = try #require(MarkerJumpPoints.compute(events: events, keptRanges: kept).first)
        #expect(track.isInsideCut == false)
        #expect(abs(track.timeSeconds - jump.timeSeconds) < 0.001,
                "the two lists disagree about a marker neither should be adjusting")
    }

    @Test("Identity and transcript survive the fold")
    func identitySurvives() throws {
        // The point of keeping it is that the user can drag or delete it, and
        // both need `Cut`-style identity to name WHICH marker.
        let event = LoggedEvent(timeSeconds: 3.0, kind: .marker, label: "inside", transcript: "said this")
        let point = try #require(MarkerTrackPoints.compute(events: [event], keptRanges: kept).first)
        #expect(point.id == event.id)
        #expect(point.transcript == "said this")
    }

    @Test("Non-marker events are still ignored")
    func onlyMarkers() {
        let events = [LoggedEvent(timeSeconds: 3.0, kind: .click),
                      LoggedEvent(timeSeconds: 3.1, kind: .keystroke)]
        #expect(MarkerTrackPoints.compute(events: events, keptRanges: kept).isEmpty)
    }
}
