// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp
@testable import SnittDocument

/// Scrolling a zoomed timeline.
///
/// Zoom was the only navigation this view had. Past 1x most of the timeline is
/// off screen, and the ± controls anchor on the playhead — so the only way to
/// look somewhere else was to move the playhead there, which means scrubbing
/// blind to find the thing you zoomed in to see.
@Suite(.serialized)
@MainActor
struct TimelineScrollTests {
    init() { _ = NSApplication.shared }

    private func view(zoomSteps: Int) -> TimelineView {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 160))
        view.update(duration: 60, cuts: [], markerPoints: [], playhead: 0)
        for _ in 0..<zoomSteps { view.zoomIn() }
        return view
    }

    @Test("At 1x there is nothing to scroll to, and the control says so")
    func notScrollableAtDefaultZoom() {
        // A scrollbar whose thumb always fills its track says "nothing to
        // scroll" in the same shape as "you are at the start of something
        // long". Absent beats inert.
        let view = view(zoomSteps: 0)
        #expect(view.isScrollable == false)
        #expect(abs(view.visibleFraction - 1) < 0.001)
    }

    @Test("Zooming in makes the timeline scrollable")
    func zoomingMakesItScrollable() {
        let view = view(zoomSteps: 2)
        #expect(view.isScrollable)
        #expect(view.visibleFraction < 0.5, "4x zoom should show under half the timeline")
    }

    @Test("Scrolling moves the viewport")
    func scrollingMovesTheViewport() {
        let view = view(zoomSteps: 2)
        let before = view.scrollFraction
        view.scroll(bySeconds: 10)
        #expect(view.scrollFraction > before, "the viewport did not move")
    }

    @Test("Scrolling clamps at both ends rather than running off")
    func scrollingClamps() {
        // Content scrollable into empty space is the failure this shares a
        // clamp with `zoomed(by:anchoredAt:)` to avoid — two different limits
        // for one axis is how that happens.
        let view = view(zoomSteps: 2)
        view.scroll(bySeconds: -10_000)
        #expect(abs(view.scrollFraction) < 0.001, "scrolled before the start")
        view.scroll(bySeconds: 10_000)
        #expect(abs(view.scrollFraction - 1) < 0.001, "scrolled past the end")
    }

    @Test("A scrollbar drag lands where it was dropped")
    func fractionRoundTrips() {
        let view = view(zoomSteps: 3)
        view.setScrollFraction(0.5)
        #expect(abs(view.scrollFraction - 0.5) < 0.01)
    }

    @Test("Zooming hands the viewport back to the anchor")
    func zoomingResetsTheScrollOverride() {
        // Zoom keeps what you were looking at under the cursor. Restoring a
        // previous scroll position on top of that would make zooming jump
        // somewhere else entirely.
        //
        // Asserted as "the viewport returned to the PLAYHEAD", not as
        // "the fraction is below 1". The first version used the latter and a
        // mutant survived it: a stale offset clamps below the new, larger
        // maximum anyway, so `< 0.99` is true whether or not the reset
        // happened. The playhead is at 0, so the anchor puts the viewport at
        // the start — and a surviving scroll position does not.
        let view = view(zoomSteps: 2)
        view.setScrollFraction(1)
        #expect(view.scrollFraction > 0.9, "the fixture did not actually scroll")
        view.zoomIn()
        #expect(view.scrollFraction < 0.01,
                "a stale scroll position survived a zoom — viewport at \(view.scrollFraction)")
    }

    @Test("Scrolling at 1x does nothing rather than shifting an axis that fits")
    func scrollingAtDefaultZoomIsInert() {
        let view = view(zoomSteps: 0)
        view.scroll(bySeconds: 30)
        #expect(abs(view.scrollFraction) < 0.001)
    }
}
