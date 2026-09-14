// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
@testable import SnittApp

// An editor window opens centred at 75% of the screen.
//
// These assert the geometry, not that a window appeared. `openingContentRect`
// is pure and takes the visible frame as a parameter precisely so it can be
// tested without a screen — the test host has none, and `NSScreen.main` is nil
// there. A test that opened a real window and read its frame back would be
// testing AppKit's placement policy, not this decision.
@Suite(.serialized)
@MainActor
struct EditorWindowGeometryTests {
    private let screen = NSRect(x: 0, y: 25, width: 1600, height: 975)

    @Test("The window is 75% of the visible frame")
    func windowIsThreeQuartersOfTheScreen() {
        let rect = EditorWindowController.openingContentRect(on: screen)
        #expect(abs(rect.width - 1200) < 0.001)
        #expect(abs(rect.height - 731.25) < 0.001)
    }

    @Test("The window is centred within the visible frame")
    func windowIsCentred() {
        let rect = EditorWindowController.openingContentRect(on: screen)
        // Centre-to-centre, both axes. Asserting width alone passes against a
        // correctly-sized window pinned to a corner — which is what the fixed
        // 640x420 effectively did.
        #expect(abs(rect.midX - screen.midX) < 0.001)
        #expect(abs(rect.midY - screen.midY) < 0.001)
    }

    @Test("The origin respects a screen that does not start at zero")
    func originRespectsScreenOffset() {
        // `visibleFrame` excludes the menu bar, so minY is not 0 on the main
        // display — and on a second display neither minX nor minY is. Centring
        // by width/2 alone would put the window off-screen; this is the
        // assertion that catches it.
        let secondary = NSRect(x: 1600, y: -400, width: 1920, height: 1080)
        let rect = EditorWindowController.openingContentRect(on: secondary)
        #expect(rect.minX > 1600)
        #expect(abs(rect.midX - secondary.midX) < 0.001)
        #expect(abs(rect.midY - secondary.midY) < 0.001)
    }

    @Test("No screen falls back to the previous fixed size")
    func noScreenFallsBack() {
        // The test host has no screen. Falling back to the old 640x420 keeps
        // headless behaviour exactly as it was rather than inventing a
        // geometry nobody can see.
        let rect = EditorWindowController.openingContentRect(on: nil)
        #expect(rect.width == 640)
        #expect(rect.height == 420)
    }

    @Test("The window's minimum is never below what its parts need")
    func minimumContentSizeCoversItsParts() {
        // This asserted EQUALITY with the derived figure until a flat 800x600
        // floor was requested (2026-09-14). The derived size is 740x423 —
        // everything technically fits there, and the transport row starts
        // dropping controls, which is where a duration wrapping one character
        // per line was reported from.
        //
        // So the relationship is now "at least", and that is the stronger
        // claim anyway: it still catches a part growing past the floor, and it
        // also catches the floor being applied in the wrong direction. A
        // `min` instead of a `max` would clip the contents rather than make
        // them small, and `EditorWindowMinimumSizeTests` pins the 800x600 half
        // that this one deliberately does not.
        // Tolerance, not `==`, matching every other geometry assertion in this
        // file. `#expect(a == b)` on these operands hits ambiguous `==`
        // overload resolution — a bare `1.0 == 1.0` inside `#expect` does not
        // even compile here — so an equality that looks exact is not reliably
        // the comparison you wrote.
        let minimum = EditorWindowController.minimumContentSize
        let expectedWidth = EditorWindowController.chaptersRailWidth
                          + EditorWindowController.minimumPlayerSize.width
        let expectedHeight = EditorWindowController.minimumPlayerSize.height
                           + TimelineLaneBudget.minimumTimelineHeight
                           + EditorWindowController.editorChromeHeight
        #expect(minimum.width >= expectedWidth - 0.001)
        #expect(minimum.height >= expectedHeight - 0.001)
    }

    @Test("At the minimum size the picture still gets more room than the timeline")
    func thePictureStaysLargestAtTheFloor() {
        // The product owner's directive, checked at the point where it is
        // hardest to honour. If the timeline out-grows the picture at the
        // smallest allowed window, the layout has inverted its own priority
        // exactly where a user is most likely to notice.
        let minimum = EditorWindowController.minimumContentSize
        let timeline = TimelineLaneBudget.timelineHeight(forWindowHeight: minimum.height)
        #expect(timeline < EditorWindowController.minimumPlayerSize.height,
                "timeline \(timeline)pt vs picture \(EditorWindowController.minimumPlayerSize.height)pt")
    }

    @Test("The opening window is comfortably larger than the minimum")
    func openingSizeClearsTheMinimum() {
        // 75% of a 1600x975 screen. If the default opening size were at or
        // below the floor, every window would open already collapsed.
        let rect = EditorWindowController.openingContentRect(on: screen)
        let minimum = EditorWindowController.minimumContentSize
        #expect(rect.width > minimum.width)
        #expect(rect.height > minimum.height)
    }

    @Test("A degenerate screen falls back rather than producing a zero-size window")
    func degenerateScreenFallsBack() {
        // A zero-width screen would otherwise yield a zero-width window: a
        // titlebar with nothing under it, which looks like a crash.
        let rect = EditorWindowController.openingContentRect(on: NSRect(x: 0, y: 0, width: 0, height: 0))
        #expect(rect.width == 640)
    }
}
