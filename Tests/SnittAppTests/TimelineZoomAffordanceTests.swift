// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
import AppKit
import SwiftUI
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
/// The wiring IS covered, by rendering the real `EditorContentView` in an
/// `NSHostingView` and letting SwiftUI build the representable itself. An
/// earlier version of this file manufactured an `NSViewRepresentable.Context`
/// from uninitialized memory to call `updateNSView` directly — undefined
/// behaviour, in a suite where this session already spent an afternoon
/// diagnosing stray memory corruption. A second version dropped that but then
/// set `state.timelineView` by hand, which made the test pass against the very
/// defect it was written for: removing the real assignment changed nothing.
/// Hosting the actual view is the version that fails when the wiring is gone.
@MainActor
struct TimelineZoomAffordanceTests {
    @Test("Rendering the editor connects the zoom buttons to a real view")
    func renderingConnectsTheZoomButtons() async throws {
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

        #expect(state.timelineView == nil, "nothing should hold a view before one is rendered")

        // The real view hierarchy the editor window builds, so SwiftUI
        // constructs the representable and calls makeNSView for us.
        let hosting = NSHostingView(rootView: EditorContentView(state: state, chrome: EditorChromeState()))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        hosting.layoutSubtreeIfNeeded()

        let handle = try #require(state.timelineView,
                                  "rendering did not connect the timeline — the zoom buttons send zoomIn() to nil")

        // And the handle drives real zoom, observed the way TimelineViewTests
        // observes it: by how much time a fixed pixel drag selects.
        var selected: Selection?
        handle.onSelect = { selected = $0 }
        handle.setFrameSize(NSSize(width: 800, height: 56))
        handle.update(duration: 600, cuts: [], markerPoints: [], playhead: 0)

        func dragWidth() -> Double {
            selected = nil
            handle.mouseDown(with: .synthetic(at: NSPoint(x: 400, y: 20), in: handle))
            handle.mouseDragged(with: .synthetic(at: NSPoint(x: 440, y: 20), in: handle))
            handle.mouseUp(with: .synthetic(at: NSPoint(x: 440, y: 20), in: handle))
            return selected.map { $0.range.end - $0.range.start } ?? -1
        }
        let unzoomed = dragWidth()
        #expect(unzoomed > 0)
        handle.zoomIn()
        #expect(dragWidth() < unzoomed / 1.5, "zoom did not reach the rendered view")
    }
}
