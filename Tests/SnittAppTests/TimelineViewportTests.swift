// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import AVFoundation
import Foundation
import SnittDocument
import SnittExport
@testable import SnittApp

/// The transport's scroll indicator has to follow the timeline.
///
/// **The bug.** `isScrollable`, `visibleFraction` and `scrollFraction` are
/// plain properties on an `NSView`, and the transport read all three during a
/// render. An `NSView` publishes nothing, so side-scrolling a zoomed timeline
/// moved the picture and left the indicator where it was.
///
/// It appeared to work while playing, because the 20Hz playhead tick was
/// re-rendering the transport for unrelated reasons and picking the new values
/// up on the way past. Paused, the indicator simply stopped saying where you
/// were — which is when a person zoomed in is most likely to be looking at it.
///
/// **This is the half of `onZoomChanged` that was missed.** That callback
/// exists for exactly this, and its own comment describes this failure in as
/// many words; only the zoom slider was wired to it.
@Suite(.serialized)
@MainActor
struct TimelineViewportTests {
    init() { _ = NSApplication.shared }

    /// A view zoomed far enough in that there is somewhere to scroll to.
    private func zoomedView() -> TimelineView {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 600, height: 80))
        view.update(duration: 120, cuts: [], markerPoints: [], playhead: 0)
        view.layoutSubtreeIfNeeded()
        view.setZoomFraction(1)
        return view
    }

    @Test("Side-scrolling tells somebody")
    func scrollingPublishes() {
        // THE REGRESSION. Verified to fail against the shipped view: with no
        // `onViewportChanged`, `seen` stays nil however far the timeline is
        // scrolled, which is the indicator standing still.
        let view = zoomedView()
        #expect(view.isScrollable, "the fixture is not zoomed in far enough to scroll")

        var seen: TimelineView.Viewport?
        view.onViewportChanged = { seen = $0 }
        view.scroll(bySeconds: 20)

        #expect(seen != nil, "a side-scroll published nothing")
        #expect((seen?.scrollFraction ?? 0) > 0,
                "the indicator was told the timeline is still at the start")
        #expect(seen?.scrollFraction == view.scrollFraction,
                "the indicator and the timeline disagree about where it is")
    }

    @Test("A scroll that moves nothing says nothing")
    func unchangedViewportIsQuiet() {
        // The guard that makes it safe to publish from `layout()`: SwiftUI
        // treats a change made during a view update as a mistake, and a layout
        // pass that moved nothing must not look like one.
        let view = zoomedView()
        var notifications = 0
        view.onViewportChanged = { _ in notifications += 1 }

        view.scroll(bySeconds: 20)
        #expect(notifications == 1)

        view.layoutSubtreeIfNeeded()
        view.scroll(bySeconds: 0)
        #expect(notifications == 1, "a scroll of zero seconds republished")
    }

    @Test("Zooming moves the viewport too, not just the slider")
    func zoomingPublishesTheViewport() {
        // Zoom changes how much is on screen — the thumb's WIDTH — and hands
        // the scroll offset back to the anchor. An indicator updated only on
        // scroll would keep a thumb sized for the old zoom.
        let view = zoomedView()
        var seen: TimelineView.Viewport?
        view.onViewportChanged = { seen = $0 }

        view.setZoomFraction(0.5)

        #expect(seen != nil, "a zoom published no viewport")
        #expect(seen?.visibleFraction == view.visibleFraction)
    }

    @Test("The state carries it, so the transport can read one source")
    func theStateMirrorsIt() async throws {
        // WRONG IMPLEMENTATION: leaving the transport reading
        // `state.timelineView?.scrollFraction`. It compiles, it is correct at
        // the instant it is read, and it is never re-read.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 2)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let state = EditorTimelineState(
            controller: PreviewController(built: built, jumpPoints: [],
                                          bundle: bundle, scale: 1.0),
            edl: EditDecisionList(), events: [])
        #expect(state.timelineViewport.scrollFraction == 0)
        #expect(state.timelineViewport.visibleFraction == 1)
        #expect(!state.timelineViewport.isScrollable)

        state.updateViewport(.init(scrollFraction: 0.4, visibleFraction: 0.25,
                                   isScrollable: true))
        #expect(state.timelineViewport.scrollFraction == 0.4)
    }
}
