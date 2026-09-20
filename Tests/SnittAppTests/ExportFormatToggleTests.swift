// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
import SwiftUI
@testable import SnittApp

/// A sheet hosting the real control, over real `@State`.
///
/// `@State` is the point. The defect below does not exist over a plain `var`,
/// so it has to be reproduced through the storage the sheet actually uses.
private struct FormatProbe: View {
    @State var request = ExportRequest(destination: URL(fileURLWithPath: "/tmp/Demo.mp4"))
    var body: some View {
        ExportSheet(title: "probe", options: [], isMeasuring: false,
                    durationSeconds: 10, request: $request,
                    onCancel: {}, onExport: {}, onChooseFolder: {})
    }
}

/// Choosing GIF has to STAY chosen.
///
/// **The bug, and why every existing test missed it.** The picker's setter
/// called `setFormat` and then `clearPreset` — two `mutating` calls on a
/// SwiftUI `@Binding`. Each one is a get, a mutate and a set, and the second
/// get came back with the value from BEFORE the first set: so `clearPreset`
/// wrote the old format back over the new one. The GIF segment lit up under
/// the pointer and snapped straight back to MP4.
///
/// `ExportSheetTests` and `ExportPresetSelectionTests` both ran that exact
/// pair and both passed, because they ran it on a `var` — where two mutations
/// in a row always work. The defect lives in the binding, not the value, so no
/// value-level test could ever have caught it. This one drives the real
/// `NSSegmentedControl` the sheet builds.
///
/// The fix is that the pair is no longer available to a call site:
/// `ExportRequest.choose(format:)` does both and `setFormat` is private.
@Suite(.serialized)
@MainActor
struct ExportFormatToggleTests {
    init() { _ = NSApplication.shared }

    private func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
        var found: [NSSegmentedControl] = []
        if let control = view as? NSSegmentedControl { found.append(control) }
        for sub in view.subviews { found.append(contentsOf: segmentedControls(in: sub)) }
        return found
    }

    @Test("Clicking GIF leaves GIF selected")
    func gifStaysSelected() throws {
        let host = NSHostingView(rootView: FormatProbe())
        let frame = NSRect(x: 0, y: 0, width: 520, height: 700)
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(window) {} }

        let picker = try #require(
            segmentedControls(in: host).first { $0.segmentCount == 2 },
            "no two-segment format control in the sheet")
        #expect(picker.label(forSegment: 0) == "MP4")
        #expect(picker.label(forSegment: 1) == "GIF")
        #expect(picker.selectedSegment == 0, "the sheet did not open on MP4")

        // What a click does: move the selection, then fire the action AppKit
        // fires. Verified to reproduce the bug — against the shipped setter
        // this leaves `selectedSegment` back at 0.
        picker.selectedSegment = 1
        if let action = picker.action { _ = picker.target?.perform(action, with: picker) }
        host.layoutSubtreeIfNeeded()

        #expect(picker.selectedSegment == 1,
                "GIF was clicked and the control snapped back to MP4")
    }

    @Test("Choosing a format is one mutation, so a binding cannot undo it")
    func chooseIsAtomic() {
        // The value-level half. It cannot catch the binding defect — nothing
        // at this level can — but it does pin that `choose` carries BOTH
        // effects, which is what makes one call at the call site correct.
        var request = ExportRequest(destination: URL(fileURLWithPath: "/tmp/Demo.mp4"))
        request.apply(.github)
        #expect(request.maxSizeBytes != nil, "the preset set no budget to clear")

        request.choose(format: "gif")

        #expect(request.format == "gif")
        #expect(request.destination.lastPathComponent == "Demo.gif")
        #expect(request.maxSizeBytes == nil, "choosing by hand left a preset budget behind")
        #expect(request.destinationPreset == nil)
    }
}
