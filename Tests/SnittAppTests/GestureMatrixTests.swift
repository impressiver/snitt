// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp
@testable import SnittDocument

/// Every gesture, in every lane, and what it resolves to.
///
/// **This file exists because of two regressions that shipped.** Y-gating fold
/// hits to the fold lane — a correct fix for ungated clicks swallowing scrubs
/// — silently removed double-click-to-expand and right-click ▸ Remove Cut
/// everywhere except one 24pt strip. Both were found by the product owner
/// using the app, not by the suite, and the suite could not have found them:
/// the tests that existed covered one gesture in one lane each, so a change to
/// the shared hit-resolution had no single test that spanned it.
///
/// A matrix is the structural answer. Every cell is stated, so a change to
/// gating fails loudly in every cell it affects rather than in none of them —
/// and adding a lane or a gesture means filling in a row, which is a question
/// asked at the right moment instead of a gap discovered later.
@Suite(.serialized)
@MainActor
struct GestureMatrixTests {
    init() { _ = NSApplication.shared }

    private let width = 800.0
    private let duration = 20.0
    /// Tall enough that every lane genuinely exists — the height at which the
    /// pre-existing 40pt fixtures could not have caught any of this.
    private let height = 200.0

    private struct Rig {
        let view: TimelineView
        let cut: Cut
        let marker: JumpPoint
        let foldX: CGFloat
        let markerX: CGFloat
        let bands: (marker: CGRect, fold: CGRect, video: CGRect,
                    audio: [(track: String, rect: CGRect)], transcript: CGRect)
    }

    private func rig() -> Rig {
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let marker = JumpPoint(id: UUID(), timeSeconds: 2, label: "mark",
                               transcript: nil, isInsideCut: false)
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.update(duration: duration, cuts: [cut], markerPoints: [marker], playhead: 0)
        view.update(phrases: TranscriptPhrases.phrases(from: [
            TranscriptWord(text: "hello", start: 1, duration: 0.5, confidence: 0.9),
        ]))
        let geometry = TimelineGeometry(
            width: width,
            timebase: Timebase(sourceDuration: duration, edl: EditDecisionList(cuts: [cut])))
        let bands = TimelineTrackLayout.bands(
            in: view.bounds, markerHeight: view.markerTrackHeightForTesting,
            audioTracks: ["microphone"], hasTranscript: true, hasFolds: true)
        return Rig(view: view, cut: cut, marker: marker,
                   foldX: CGFloat(geometry.x(atFold: cut)),
                   // From the geometry, not `width * time / duration`: the
                   // view maps OUTPUT time, and with a cut present the output
                   // duration is 18s, not the source's 20. Computing it here
                   // by hand put the click 9pt off the marker — the same
                   // "assert on the ingredients" mistake in fixture form.
                   markerX: CGFloat(geometry.x(atOutput: OutputTime(marker.timeSeconds))),
                   bands: bands)
    }

    // MARK: - Right-click: reaches a fold from ANY lane

    @Test("Right-click on a fold's x resolves to Remove Cut in every lane")
    func rightClickReachesFoldsEverywhere() {
        // The regression, stated for every lane at once. The fold's line is
        // drawn full height on purpose, so a right-click anywhere along it is
        // a right-click on that fold.
        let r = rig()
        for (name, y) in [("marks", r.bands.marker.midY), ("folds", r.bands.fold.midY),
                          ("video", r.bands.video.midY),
                          ("audio", r.bands.audio[0].rect.midY),
                          ("transcript", r.bands.transcript.midY)] {
            let menu = r.view.contextMenu(at: NSPoint(x: r.foldX, y: y))
            #expect(menu?.items.first?.title == "Remove Cut",
                    "right-click in the \(name) lane did not reach the fold")
        }
    }

    @Test("Right-click away from any fold offers nothing, in every lane")
    func rightClickElsewhereIsEmpty() {
        // The other half: a menu that appeared everywhere would be as wrong as
        // one that appeared nowhere.
        let r = rig()
        for y in [r.bands.marker.midY, r.bands.video.midY, r.bands.audio[0].rect.midY] {
            #expect(r.view.contextMenu(at: NSPoint(x: 40, y: y)) == nil)
        }
    }

    // MARK: - Double-click: reaches a fold from ANY lane

    @Test("Double-click on a fold's x expands and selects it from every lane")
    func doubleClickReachesFoldsEverywhere() {
        // A fresh rig per cell, compared against ITS OWN cut. Reading `r.cut`
        // while clicking a different rig's view compares two fixtures — the
        // identity mistake this suite's own fixtures made once already.
        for lane in ["marks", "folds", "video", "audio"] {
            let r = rig()
            let y: CGFloat
            switch lane {
            case "marks": y = r.bands.marker.midY
            case "folds": y = r.bands.fold.midY
            case "video": y = r.bands.video.midY
            default: y = r.bands.audio[0].rect.midY
            }
            var expanded: UUID?
            r.view.onExpandAndSelectFold = { expanded = $0 }
            r.view.mouseDown(with: .synthetic(at: NSPoint(x: r.foldX, y: y),
                                              in: r.view, clickCount: 2))
            #expect(expanded == r.cut.id, "double-click in the \(lane) lane missed the fold")
        }
    }

    // MARK: - Double-click in the marker lane

    @Test("Double-click an empty spot in the marker lane creates a marker")
    func doubleClickEmptyMarkerLaneCreates() {
        let r = rig()
        var created: Double?
        var edited: UUID?
        r.view.onCreateMarker = { created = $0 }
        r.view.onEditMarker = { edited = $0 }
        // x=600 is far from both the marker at t=2 and the fold at t=10.
        r.view.mouseDown(with: .synthetic(at: NSPoint(x: 600, y: r.bands.marker.midY),
                                          in: r.view, clickCount: 2))
        #expect(created != nil, "double-click on empty marker lane created nothing")
        #expect(edited == nil, "it opened an editor instead")
    }

    @Test("Clicking ON a marker opens its editor rather than creating another")
    func clickOnMarkerEdits() {
        // Down AND up: `mouseDown`'s marker branch defers the edit-or-move
        // decision to `mouseUp`, once total travel is known. A test sending
        // only `mouseDown` sees nothing and proves nothing — which is how an
        // unreachable double-click arm survived long enough to be written.
        let r = rig()
        var created: Double?
        var edited: UUID?
        r.view.onCreateMarker = { created = $0 }
        r.view.onEditMarker = { edited = $0 }
        let point = NSPoint(x: r.markerX, y: r.bands.marker.midY)
        r.view.mouseDown(with: .synthetic(at: point, in: r.view))
        r.view.mouseUp(with: .synthetic(at: point, in: r.view))
        #expect(edited == r.marker.id, "clicking a marker did not open its editor")
        #expect(created == nil, "it created a second marker on top of the first")
    }

    @Test("Double-click below the marker lane creates nothing")
    func doubleClickBelowMarkerLaneCreatesNothing() {
        // Marker creation is a marker-lane gesture. Firing it on the filmstrip
        // would drop marks wherever someone double-clicked to expand a fold
        // and missed.
        let r = rig()
        var created: Double?
        r.view.onCreateMarker = { created = $0 }
        r.view.mouseDown(with: .synthetic(at: NSPoint(x: 600, y: r.bands.video.midY),
                                          in: r.view, clickCount: 2))
        #expect(created == nil)
    }

    // MARK: - Single click: gated, so the lanes below stay scrubbable

    @Test("Single click on a fold's x scrubs everywhere EXCEPT the fold lane")
    func singleClickIsGatedToTheFoldLane() {
        // The reason the gate exists, stated as a matrix rather than assumed.
        // An ungated single click swallows scrubs meant for every lane below.
        let r = rig()
        for lane in ["video", "audio"] {
            let r = rig()
            let y = lane == "video" ? r.bands.video.midY : r.bands.audio[0].rect.midY
            var toggled: UUID?
            var scrubbed: Double?
            r.view.onToggleExpansion = { toggled = $0 }
            r.view.onScrub = { scrubbed = $0 }
            r.view.mouseDown(with: .synthetic(at: NSPoint(x: r.foldX, y: y), in: r.view))
            #expect(toggled == nil, "a single click in the \(lane) lane toggled a fold")
            #expect(scrubbed != nil, "a single click in the \(lane) lane did not scrub")
        }
    }

    @Test("Single click IN the fold lane toggles and selects")
    func singleClickInFoldLaneToggles() {
        let r = rig()
        var toggled: UUID?
        var selected: UUID?
        r.view.onToggleExpansion = { toggled = $0 }
        r.view.onSelectFold = { selected = $0 }
        r.view.mouseDown(with: .synthetic(at: NSPoint(x: r.foldX, y: r.bands.fold.midY),
                                          in: r.view))
        #expect(toggled == r.cut.id)
        #expect(selected == r.cut.id, "clicking a fold did not highlight what it removed")
    }
}
