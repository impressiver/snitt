// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import SwiftUI
@testable import SnittApp
@testable import SnittDocument

// The export sheet's headline figures (rev 5, W5).
//
// The feature is "an export priced before you commit", and until now both
// numbers were caption-sized, one per row. Promoting them is the change; these
// pin the two facts that make the promotion honest — that the duration is
// carried from the estimator rather than invented, and that the ceiling keeps
// the wording the CLI and the MCP tool already use.
@Suite
struct ExportHeadlineTests {

    @Test("The duration reaches the menu from the estimate that measured it")
    func durationIsCarriedThrough() {
        // `ExportOption` grew a field, and a field nothing populates is the
        // "correct model, no pixels" defect in miniature: the sheet would
        // show 0:00 for every export while every other test stayed green.
        let estimates = [ExportEstimate(resolution: .source, durationSeconds: 26.3,
                                        width: 1512, height: 982,
                                        estimatedMaxBytes: 41_000_000, basis: "test"),
                         ExportEstimate(resolution: .hd720p, durationSeconds: 26.3,
                                        width: 1280, height: 831,
                                        estimatedMaxBytes: 24_000_000, basis: "test")]
        let options = ExportPreflight.options(from: estimates)
        #expect(options.count == 2)
        for option in options {
            #expect(abs(option.durationSeconds - 26.3) < 0.001,
                    "\(option.resolution) carries \(option.durationSeconds)")
        }
    }

    @Test("A duration reads as minutes and padded seconds")
    func lengthFormatsLikeEverywhereElse() {
        // The same shape the transport and the marker rail use, so a duration
        // reads the same wherever it appears.
        #expect(ExportPreflight.length(seconds: 26.3) == "0:26")
        #expect(ExportPreflight.length(seconds: 0) == "0:00")
        #expect(ExportPreflight.length(seconds: 65) == "1:05")
        #expect(ExportPreflight.length(seconds: 5) == "0:05", "seconds below ten must pad")
        #expect(ExportPreflight.length(seconds: 3599.6) == "60:00", "rounds, not truncates")
    }

    @Test("The ceiling still says 'at most', not '≈'")
    func ceilingKeepsItsHonestWording() {
        // `estimatedMaxBytes` is an upper bound, not a prediction — the real
        // file has come in around a quarter of it. An earlier draft of this
        // design showed "≈ 20.8 MB" in both mockups, which would have promised
        // an accuracy the number does not have and disagreed with `snitt
        // estimate`, which says "at most". Three surfaces, one sentence.
        let text = ExportPreflight.ceiling(bytes: 20_800_000)
        #expect(text.contains("at most"), "the ceiling now reads \(text)")
        #expect(!text.contains("≈"), "the ceiling promises a prediction: \(text)")
    }

    // NOT TESTED HERE, deliberately and with the reason recorded: that the
    // two figures are *on the sheet* and sized as headlines. Rendering an
    // `ExportSheet` through `NSHostingView` — with and without a real window,
    // with a display cycle — produces neither `NSTextField` subviews nor a
    // populated accessibility tree in this headless test host, so every
    // version of that assertion passed or failed for reasons unrelated to the
    // design. Rather than keep a test whose green means nothing, the
    // placement is verified by rendering the built app and looking at it,
    // which is what the fleet protocol requires after a visual change anyway.
    //
    // What IS covered above is what could actually go wrong silently: a field
    // nothing populates, a format that drifts, and wording that stops
    // matching the CLI.
}
