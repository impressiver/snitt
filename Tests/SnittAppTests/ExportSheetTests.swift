// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// What the export sheet decides, asserted against the decisions rather than
/// against the view.
///
/// The sheet replaced an `NSSavePanel` carrying an `NSPopUpButton` in its
/// accessory slot, and the panel's tests went with it. They asserted the
/// popup's titles and enabled-state — properties of a control, all of which a
/// view rewrite invalidates and none of which say what the export will be.
/// These assert `ExportRequest`, which is the thing handed to `MovieExporter`.
@Suite(.serialized)
@MainActor
struct ExportSheetTests {
    init() { _ = NSApplication.shared }

    private let file = URL(fileURLWithPath: "/Users/somebody/Movies/Demo.mp4")

    @Test("An untouched request exports what the app always exported")
    func defaultsAreTheOldBehaviour() {
        // The sheet is new; what pressing Export without touching anything
        // does must not be. Source resolution, MP4, no click marks (D64).
        let request = ExportRequest(destination: file)
        #expect(request.format == "mp4")
        #expect(request.resolution == .source)
        #expect(request.drawClicks == false)
        #expect(request.destination == file)
    }

    @Test("Choosing GIF renames the file rather than appending to it")
    func formatReplacesTheExtension() {
        // The wrong implementation is `appendingPathExtension` alone, which
        // yields `Demo.mp4.gif`: a name Finder shows as a GIF and every
        // sorting-by-name view files under the wrong thing. It is one call
        // away from correct and looks right in a debugger.
        var request = ExportRequest(destination: file)
        request.choose(format: "gif")
        #expect(request.destination.lastPathComponent == "Demo.gif")
    }

    @Test("Switching back to MP4 does not accumulate extensions")
    func formatRoundTripsCleanly() {
        // Someone toggling the segmented control to see both options must not
        // end up at `Demo.gif.mp4`. This is the assertion the single-direction
        // test above cannot make.
        var request = ExportRequest(destination: file)
        request.choose(format: "gif")
        request.choose(format: "mp4")
        #expect(request.destination.lastPathComponent == "Demo.mp4")
        #expect(request.format == "mp4")
    }

    @Test("Dots inside the name survive a format change")
    func dottedNamesKeepTheirDots() {
        // `Demo.v2.final.mp4` is a real filename. An implementation that
        // split on the first dot renames it to `Demo.gif` and silently
        // discards the part its owner used to tell versions apart.
        var request = ExportRequest(
            destination: URL(fileURLWithPath: "/tmp/Demo.v2.final.mp4"))
        request.choose(format: "gif")
        #expect(request.destination.lastPathComponent == "Demo.v2.final.gif")
    }

    @Test("Size estimates are claimed for MP4 and disclaimed for GIF")
    func estimatesApplyOnlyToMP4() {
        // `ExportEstimator` refuses to estimate a GIF — a GIF's weight tracks
        // how much the picture moves and AVFoundation's number describes an
        // H.264 export. The sheet still shows the rows, so this flag is what
        // stops it presenting an H.264 figure as if it applied.
        var request = ExportRequest(destination: file)
        #expect(request.estimatesApply)
        request.choose(format: "gif")
        #expect(request.estimatesApply == false)
    }

    // `defaultDestinationSitsBesideTheBundle` lived here and asserted that an
    // export lands beside its bundle. That decision is reversed (exports now
    // default to `~/Downloads`, then to wherever you last exported), so the
    // test moved rather than being deleted: `LastExportDirectoryTests` owns
    // the new behaviour, and keeps BOTH halves of the old one — the folder
    // question, now parameterised, and the part that was never about the
    // folder, that a `.snitt` is itself a directory and an export must not be
    // written inside it.

    @Test("Each Export request raises the sheet again")
    func everyRequestIsDistinct() async throws {
        // The signal is a counter because a `Bool` left true swallows the
        // second press: cancel the sheet, press Export again, nothing
        // happens. Asserting the count moves proves the second press is
        // observable, which "the flag is true" does not.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 1.0)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let state = EditorTimelineState(
            controller: PreviewController(built: built, jumpPoints: [],
                                          bundle: bundle, scale: 1.0),
            edl: EditDecisionList(), events: [])

        let first = state.exportRequestToken
        state.requestExport()
        state.requestExport()
        #expect(state.exportRequestToken == first + 2)
    }
}
