// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp
@testable import SnittDocument

/// Hovering the filmstrip previews that instant; leaving snaps back.
///
/// **This file is Step 0, and it was written before the feature.**
/// `docs/superpowers/specs/2026-09-10-snitt-rev5-ui.md:596` makes that a hard
/// gate for any timeline gesture change, by product-owner ruling: *"write the
/// collision test BEFORE any other change, and let it decide the item's
/// shape."* The reasoning there is that a directive about DRAWING becomes a
/// change to GESTURES by accident, because right-click and double-click
/// already reach a fold from every lane and only single click is y-gated.
/// `TimelineView.swift:536`: *"an ungated full-height hit swallows clicks
/// meant for each of them, three times over."*
///
/// **What the gate decided, and it is not what the plan assumed.** The plan
/// put the lane gate in an `NSTrackingArea` whose rect is the filmstrip band.
/// Writing these tests first showed that is the wrong place for it:
///
/// 1. A test drives `mouseMoved(with:)` directly, so a tracking rect gates
///    nothing a test can see. A gate that only exists in the rect is a gate
///    with no test, on the one view in this project whose gating has already
///    regressed twice.
/// 2. The rect goes stale. `update(duration:...audioLanes:...)` and
///    `update(phrases:)` both change the filmstrip band's height — audio lane
///    count and transcript presence are inputs to
///    `TimelineTrackLayout.bands` — and both end in `needsDisplay = true`
///    without touching tracking areas, which AppKit only re-fires on a real
///    bounds change. A stale rect would then deliver hover for the wrong
///    strip.
///
/// So the y-gate lives in the handler, where it is tested, and the tracking
/// area is only an event-delivery optimisation. With the gate in the handler,
/// a stale rect is harmless: the handler simply rejects a point outside the
/// band. That inverts the plan's dependency and is the shape these tests pin.
@Suite(.serialized)
@MainActor
struct FilmstripHoverTests {
    init() { _ = NSApplication.shared }

    private let width = 800.0
    private let duration = 20.0
    /// Tall enough that every lane genuinely exists, matching
    /// `GestureMatrixTests` — at the older 40pt fixture height the lanes
    /// collapse and a y-gate test proves nothing.
    private let height = 200.0

    private struct Rig {
        let view: TimelineView
        let cut: Cut
        let marker: JumpPoint
        let foldX: CGFloat
        let bands: (marker: CGRect, video: CGRect,
                    audio: [(track: String, rect: CGRect)], transcript: CGRect)
    }

    private func rig() -> Rig {
        let cut = Cut(range: TimeRange(start: 10, end: 12))
        let marker = JumpPoint(id: UUID(), timeSeconds: 2, label: "mark",
                               transcript: nil, isInsideCut: false)
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        // `audioLanes` passed EXPLICITLY, and the fixture's `bands` below use
        // the same list. Without it the view falls back to
        // `AudioTrackOrder.recorded(in: [], ...)`, which yields no audio lane
        // at all, so the filmstrip absorbs the audio band's height and the
        // fixture's "audio lane" y lands INSIDE the real filmstrip. These
        // tests failed exactly that way first: a y-gate test whose fixture
        // disagrees with the view about where the lanes are proves nothing.
        view.update(duration: duration, cuts: [cut], markerPoints: [marker],
                    playhead: 0, audioLanes: ["microphone"])
        view.update(phrases: TranscriptPhrases.phrases(from: [
            TranscriptWord(text: "hello", start: 1, duration: 0.5, confidence: 0.9),
        ]))
        let geometry = TimelineGeometry(
            width: width,
            timebase: Timebase(sourceDuration: duration, edl: EditDecisionList(cuts: [cut])))
        let bands = TimelineTrackLayout.bands(
            in: view.bounds, markerHeight: view.markerTrackHeightForTesting,
            audioTracks: ["microphone"], hasTranscript: true)
        return Rig(view: view, cut: cut, marker: marker,
                   foldX: CGFloat(geometry.x(atFold: cut)), bands: bands)
    }

    // MARK: - The collision matrix: which lanes hover, and which stay inert

    @Test("Hover previews in the filmstrip lane and in no other lane")
    func hoverIsGatedToTheFilmstripLane() {
        let r = rig()
        var previews: [Double?] = []
        r.view.onHoverPreview = { previews.append($0) }

        // An x well clear of the fold and the marker, so nothing else could
        // plausibly claim the point and a failure here means the y-gate.
        let x = 400.0

        r.view.mouseMoved(with: .syntheticMove(at: NSPoint(x: x, y: r.bands.marker.midY),
                                               in: r.view))
        #expect(previews.isEmpty, "the marker lane must not preview")

        for (track, rect) in r.bands.audio {
            r.view.mouseMoved(with: .syntheticMove(at: NSPoint(x: x, y: rect.midY),
                                                   in: r.view))
            #expect(previews.isEmpty, "the \(track) audio lane must not preview")
        }

        r.view.mouseMoved(with: .syntheticMove(at: NSPoint(x: x, y: r.bands.transcript.midY),
                                               in: r.view))
        #expect(previews.isEmpty, "the transcript lane must not preview")

        r.view.mouseMoved(with: .syntheticMove(at: NSPoint(x: x, y: r.bands.video.midY),
                                               in: r.view))
        #expect(previews.count == 1, "the filmstrip lane previews")
        #expect(previews.first.flatMap { $0 } != nil, "and it reports a time, not an exit")
    }

    /// What a single click in one lane resolved to.
    ///
    /// Compared as a whole rather than field by field so that adding a
    /// callback to the view adds it to this comparison too, instead of
    /// quietly falling outside it.
    private struct ClickOutcome: Equatable {
        var scrubs: [Double] = []
        var created: [Double] = []
        var toggled: [UUID] = []
        var expandedAndSelected: [UUID] = []
        var removed: [UUID] = []
        var selections: [Selection?] = []
    }

    private func clickOutcome(inLaneAt y: CGFloat, x: CGFloat,
                              hoveringFirst: Bool) -> ClickOutcome {
        let r = rig()
        var outcome = ClickOutcome()
        r.view.onScrub = { outcome.scrubs.append($0) }
        r.view.onCreateMarker = { outcome.created.append($0) }
        r.view.onToggleExpansion = { outcome.toggled.append($0) }
        r.view.onExpandAndSelectFold = { outcome.expandedAndSelected.append($0) }
        r.view.onRemoveCut = { outcome.removed.append($0) }
        r.view.onSelect = { outcome.selections.append($0) }

        let point = NSPoint(x: x, y: y)
        if hoveringFirst {
            r.view.mouseMoved(with: .syntheticMove(at: point, in: r.view))
        }
        r.view.mouseDown(with: .synthetic(at: point, in: r.view))
        r.view.mouseUp(with: .synthetic(at: point, in: r.view))
        return outcome
    }

    @Test("Hover changes no lane's single-click meaning")
    func hoverDoesNotDisturbTheClickMatrix() {
        // THE ACTUAL COLLISION TEST, and the reason the Step 0 ruling exists.
        // The hazard is not "does hover work" but "did adding hover quietly
        // take a click away from a lane".
        //
        // DIFFERENTIAL, not absolute: it clicks each lane with and without a
        // preceding hover and asserts the two outcomes are identical. That
        // deliberately encodes no opinion about what any lane's click MEANS.
        // `GestureMatrixTests.singleClickIsGatedToTheFoldLane` owns that
        // question and pointedly does not assert it for the marker lane
        // ("The marker lane has its own meaning for a click and does not
        // scrub") without pinning it either way. Asserting a baseline here
        // would mean inventing one, and a collision test that depends on an
        // invented baseline fails for the wrong reason the day the baseline
        // changes.
        let r = rig()
        let lanes: [(String, CGFloat)] = [
            ("marker", r.bands.marker.midY),
            ("filmstrip", r.bands.video.midY),
            ("audio", r.bands.audio.first?.rect.midY ?? r.bands.video.midY),
            ("transcript", r.bands.transcript.midY),
        ]
        // Two x positions: one clear of everything, and one on the fold's
        // seam, which is where the gating this view has regressed twice
        // actually bites.
        for (lane, y) in lanes {
            for (label, x) in [("clear", CGFloat(400)), ("on the fold seam", r.foldX)] {
                let baseline = clickOutcome(inLaneAt: y, x: x, hoveringFirst: false)
                let hovered = clickOutcome(inLaneAt: y, x: x, hoveringFirst: true)
                #expect(baseline == hovered,
                        "hovering changed what a click \(label) in the \(lane) lane does")
            }
        }
    }

    /// Assertions never SUBSCRIPT `previews`.
    ///
    /// `previews[1]` reads naturally and turns any count mismatch into an
    /// index-out-of-range crash on top of the assertion failure. The formal
    /// mutation run reported one of these as "killed (crash)" rather than a
    /// clean kill, and in a project whose CI comment opens with "`swift test`
    /// EXITS 0 WHEN THE TEST BUNDLE SEGFAULTS" a test that can crash the
    /// bundle is a liability even when it is failing for the right reason.
    /// `previews.last == .some(nil)` says "there is a last element and it is
    /// an exit" without indexing.
    @Test("Leaving the filmstrip reports an exit exactly once")
    func exitReportsNilOnce() {
        let r = rig()
        var previews: [Double?] = []
        r.view.onHoverPreview = { previews.append($0) }

        r.view.mouseMoved(with: .syntheticMove(at: NSPoint(x: 400, y: r.bands.video.midY),
                                               in: r.view))
        r.view.mouseExited(with: .syntheticMove(at: NSPoint(x: 400, y: r.bands.video.midY),
                                                in: r.view))
        #expect(previews.count == 2)
        #expect(previews.last == .some(nil), "the exit is reported as nil")

        // A second exit with no intervening hover must stay quiet, or every
        // pointer wander near the edge re-seeks the player back to a position
        // it is already at.
        r.view.mouseExited(with: .syntheticMove(at: NSPoint(x: 400, y: r.bands.video.midY),
                                                in: r.view))
        #expect(previews.count == 2, "a redundant exit reports nothing")
    }

    @Test("Moving out of the filmstrip band without leaving the view reports an exit")
    func leavingTheBandIsAnExit() {
        // The tracking area covers the band, but the view is taller than the
        // band, and AppKit delivers `mouseMoved` for the whole view once any
        // tracking area is active. So sliding from the filmstrip down into a
        // waveform is an exit even though no `mouseExited` fires.
        let r = rig()
        var previews: [Double?] = []
        r.view.onHoverPreview = { previews.append($0) }

        r.view.mouseMoved(with: .syntheticMove(at: NSPoint(x: 400, y: r.bands.video.midY),
                                               in: r.view))
        #expect(previews.count == 1)
        r.view.mouseMoved(with: .syntheticMove(
            at: NSPoint(x: 400, y: r.bands.audio.first?.rect.midY ?? 0), in: r.view))
        #expect(previews.count == 2)
        #expect(previews.last == .some(nil), "sliding out of the band snaps back")
    }

    @Test("A zoom while hovering cancels the preview")
    func zoomWhileHoveringCancels() {
        // D3, ruling on the CLASS rather than its instances: the hover
        // point-to-time mapping has invalidation triggers that are not mouse
        // events. `setZoom` funnels zoomIn/zoomOut/scrollWheel/magnify and
        // calls `rebuildGeometry()` with no reference to any pointer, so the
        // pointer stays still while the time under it changes. Cancelling is
        // chosen over recomputing from a cached point because it adds no new
        // state to a view whose gesture state has already regressed twice.
        let r = rig()
        var previews: [Double?] = []
        r.view.onHoverPreview = { previews.append($0) }

        r.view.mouseMoved(with: .syntheticMove(at: NSPoint(x: 400, y: r.bands.video.midY),
                                               in: r.view))
        #expect(previews.count == 1)
        r.view.zoomIn()
        #expect(previews.count == 2, "a zoom under a still pointer cancels the preview")
        #expect(previews.last == .some(nil))
    }

    @Test("A lane-count change while hovering cancels the preview")
    func laneChangeWhileHoveringCancels() {
        // The other half of D3's class, and the half a tracking rect gets
        // wrong: adding an audio lane shrinks the filmstrip band, so the
        // point under the pointer may no longer be in it.
        let r = rig()
        var previews: [Double?] = []
        r.view.onHoverPreview = { previews.append($0) }

        r.view.mouseMoved(with: .syntheticMove(at: NSPoint(x: 400, y: r.bands.video.midY),
                                               in: r.view))
        #expect(previews.count == 1)
        r.view.update(duration: duration, cuts: [r.cut], markerPoints: [r.marker],
                      playhead: 0, audioLanes: ["microphone", "system"])
        #expect(previews.count == 2, "a band resize under a still pointer cancels")
        #expect(previews.last == .some(nil))
    }

    @Test("A drag that began in the filmstrip is not interrupted by hover")
    func dragSuppressesHover() {
        // A trim drag sends `mouseDragged`, and AppKit also delivers
        // `mouseMoved` around it. Previewing mid-drag would fight the
        // selection the drag is making.
        let r = rig()
        var previews: [Double?] = []
        r.view.onHoverPreview = { previews.append($0) }

        let start = NSPoint(x: 300, y: r.bands.video.midY)
        r.view.mouseDown(with: .synthetic(at: start, in: r.view))
        r.view.mouseMoved(with: .syntheticMove(at: NSPoint(x: 400, y: r.bands.video.midY),
                                               in: r.view))
        #expect(previews.isEmpty, "no preview while a gesture owns the pointer")
        r.view.mouseUp(with: .synthetic(at: NSPoint(x: 400, y: r.bands.video.midY),
                                        in: r.view))
    }
}

extension NSEvent {
    /// A synthetic `mouseMoved`, not a `leftMouseDown` wearing its location.
    ///
    /// `TimelineViewTests.synthetic` hardcodes `.leftMouseDown`, which is
    /// right for the click matrix and wrong here: a hover handler that
    /// happened to read `event.type` would see a payload no pointer move ever
    /// produces, which is the mistake that file's own doc comment warns about
    /// for key events. Pressure is 0 because nothing is pressed.
    @MainActor
    static func syntheticMove(at point: NSPoint, in view: NSView) -> NSEvent {
        let location = view.isFlipped
            ? NSPoint(x: point.x, y: view.bounds.height - point.y)
            : point
        return NSEvent.mouseEvent(
            with: .mouseMoved,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0)!
    }
}
