import Testing
import Foundation
import AppKit
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// The on-screen zoom controls.
///
/// `TimelineView.zoomIn()`/`zoomOut()` have worked and been tested since M5f
/// Task 8 (`TimelineViewTests`). What did not exist was any on-screen way to
/// reach them — the only routes in were a trackpad pinch and a keyboard
/// shortcut on a view that has to be first responder — so the zoom the editor
/// needed for `TrimGesture`'s density problem was effectively undiscoverable.
///
/// WHAT THIS DOES NOT COVER, stated plainly rather than faked: that
/// `TimelineViewRepresentable` hands the view to the state. Driving
/// `makeNSView`/`updateNSView` needs an `NSViewRepresentable.Context`, which
/// cannot be constructed outside SwiftUI. A first version of this file
/// manufactured one from uninitialized memory; that is undefined behaviour, and
/// this project has just spent an afternoon proving how expensive stray memory
/// corruption is to diagnose in a test suite. A test that might corrupt the run
/// is worse than an honest gap.
@MainActor
struct TimelineZoomAffordanceTests {
    @Test("A view held by the state zooms when the buttons ask it to")
    func zoomFlowsThroughTheStateHandle() async throws {
        // This is exactly what the "+"/"−" buttons do:
        // `state.timelineView?.zoomIn()`. With a nil handle that line is a
        // silent no-op indistinguishable from a working control, so the handle
        // is required non-nil before the behaviour is checked.
        //
        // Zoom is observed the way `TimelineViewTests` observes it — by how
        // much time a fixed pixel drag selects — rather than through a
        // test-only accessor, so this measures the same thing a user feels.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 4.0)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
        let state = EditorTimelineState(controller: controller, edl: EditDecisionList(), events: [])

        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 800, height: 56))
        var selected: Selection?
        view.onSelect = { selected = $0 }
        view.update(duration: 600, cuts: [], jumpPoints: [], playhead: 0)
        state.timelineView = view

        func dragSelectionWidth() -> Double {
            selected = nil
            view.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: view))
            view.mouseDragged(with: .synthetic(at: NSPoint(x: 440, y: 20), in: view))
            view.mouseUp(with: .synthetic(at: NSPoint(x: 440, y: 20), in: view))
            guard let selected else { return -1 }
            return selected.range.end - selected.range.start
        }

        let handle = try #require(state.timelineView, "buttons would send zoomIn() to nil")
        let unzoomed = dragSelectionWidth()
        #expect(unzoomed > 0)

        handle.zoomIn()
        let zoomedIn = dragSelectionWidth()
        #expect(zoomedIn < unzoomed / 1.5,
                "zoomIn through the state handle did not change the scale")

        handle.zoomOut()
        #expect(abs(dragSelectionWidth() - unzoomed) < 0.1,
                "zoomOut did not undo zoomIn")
    }
}
