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

    @Test("A degenerate screen falls back rather than producing a zero-size window")
    func degenerateScreenFallsBack() {
        // A zero-width screen would otherwise yield a zero-width window: a
        // titlebar with nothing under it, which looks like a crash.
        let rect = EditorWindowController.openingContentRect(on: NSRect(x: 0, y: 0, width: 0, height: 0))
        #expect(rect.width == 640)
    }
}
