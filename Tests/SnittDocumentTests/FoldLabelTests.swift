import Foundation
import Testing
@testable import SnittDocument

/// Naming a fold from the markers around it.
@Suite
struct FoldLabelTests {

    private func marker(_ t: Double, _ label: String?) -> LoggedEvent {
        LoggedEvent(timeSeconds: t, kind: .marker, label: label)
    }

    @Test("A fold is named for what was happening when the gap began")
    func namedForTheMarkerBefore() {
        // The usual case, and the one the feature exists for: an agent marks
        // "running the build", then four minutes pass with nothing on screen.
        let text = FoldLabel.describe(
            span: TimeRange(start: 100, end: 352),
            markers: [marker(10, "opening the project"), marker(98, "running the build")])
        #expect(text == "running the build — 4m 12s")
    }

    @Test("A marker inside the fold wins over one before it")
    func markerInsideWins() {
        // Only reachable for a hand-made cut — an automatic trim never folds
        // over a marker, since markers veto dead air (D57). When it happens the
        // inside marker describes the removed material directly, and the one
        // before describes something that survived.
        let text = FoldLabel.describe(
            span: TimeRange(start: 100, end: 160),
            markers: [marker(90, "before"), marker(120, "inside")])
        #expect(text == "inside — 1m")
    }

    @Test("With nothing to draw on, the duration alone")
    func fallsBackToDuration() {
        // Less than the feature promises, and still better than a nameless
        // band — but it must not invent a description.
        #expect(FoldLabel.describe(span: TimeRange(start: 0, end: 45), markers: [])
                == "45s")
    }

    @Test("Only labelled markers name a fold")
    func unlabelledMarkersAndOtherEventsAreIgnored() {
        // A click is not a description, and a marker with no label is the
        // generated "Marker 3" the panel shows — neither says what happened.
        let events = [
            LoggedEvent(timeSeconds: 90, kind: .click, x: 0.5, y: 0.5, source: .reported),
            marker(95, nil),
            marker(96, ""),
        ]
        #expect(FoldLabel.describe(span: TimeRange(start: 100, end: 130), markers: events)
                == "30s")
    }

    @Test("A marker after the fold does not name it")
    func markersAfterAreIgnored() {
        // It describes what came next, not what was skipped.
        #expect(FoldLabel.describe(span: TimeRange(start: 100, end: 130),
                                   markers: [marker(200, "afterwards")]) == "30s")
    }

    @Test("Durations read in the shortest unambiguous form")
    func durationFormatting() {
        #expect(FoldLabel.duration(45) == "45s")
        #expect(FoldLabel.duration(60) == "1m")
        #expect(FoldLabel.duration(252) == "4m 12s")
        #expect(FoldLabel.duration(3600) == "1h")
        #expect(FoldLabel.duration(3720) == "1h 2m")
        // Rounded, not truncated toward zero, and never negative.
        #expect(FoldLabel.duration(0.6) == "1s")
        #expect(FoldLabel.duration(-5) == "0s")
    }
}

/// `Cut.label` on disk (D60's schema gate).
@Suite
struct CutLabelCodingTests {

    @Test("A label survives a round trip")
    func labelRoundTrips() throws {
        let cut = Cut(range: TimeRange(start: 1, end: 2), label: "waiting for build — 4m 12s")
        let decoded = try JSONDecoder().decode(Cut.self, from: JSONEncoder().encode(cut))
        #expect(decoded.label == "waiting for build — 4m 12s")
        #expect(decoded.id == cut.id)
    }

    @Test("An edit.json written before labels existed still opens")
    func legacyCutsDecode() throws {
        // Every cut in every bundle made before today has no `label` key, and
        // D54 makes updates hand-delivered, so old and new files coexist on one
        // machine. A required key here would make those bundles unopenable.
        let json = Data(#"{"start": 1.0, "end": 2.0}"#.utf8)
        let cut = try JSONDecoder().decode(Cut.self, from: json)
        #expect(cut.label == nil)
        #expect(cut.range.start == 1.0)
    }

    @Test("An unlabelled cut writes no label key at all")
    func unlabelledCutsWriteNoKey() throws {
        // `edit.json` is a file a person might open. A hand-made cut is
        // unlabelled by design, and a file full of `"label": null` is noise.
        let data = try JSONEncoder().encode(Cut(range: TimeRange(start: 1, end: 2)))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("label"), "wrote a null label: \(text)")
    }
}
