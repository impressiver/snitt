// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittApp
@testable import SnittDocument

/// The export menu shown before committing to an export.
///
/// Every test here is against the two decisions that can be wrong on their own:
/// which resolutions are worth OFFERING, and how honestly the size is worded.
/// Neither needs a save panel to be wrong, which is why neither lives in one.
@Suite
struct ExportPreflightTests {

    /// What `ExportEstimator.menu` returns for a 1512×982 recording — the
    /// ordinary case, a Mac screen. Sizes come from `renderSize`'s own rule:
    /// a preset never enlarges, so every preset at or above the source's long
    /// edge returns it unchanged.
    private static func macScreenEstimates() -> [ExportEstimate] {
        func e(_ r: ExportResolution, _ w: Int, _ h: Int, _ bytes: Int) -> ExportEstimate {
            ExportEstimate(resolution: r, durationSeconds: 26.3, width: w, height: h,
                           estimatedMaxBytes: bytes, basis: "test")
        }
        return [
            e(.source, 1512, 982, 41_000_000),
            e(.uhd2160p, 1512, 982, 41_000_000),
            e(.hd1080p, 1512, 982, 41_000_000),
            e(.hd720p, 1280, 831, 24_000_000),
            e(.sd540p, 960, 623, 13_000_000),
            e(.sd480p, 640, 416, 6_400_000),
        ]
    }

    @Test("Resolutions that render identically are offered once, not three times")
    func duplicateRenderSizesCollapse() {
        // The defect this exists to prevent. A preset never enlarges, so on a
        // 1512-wide recording source, 2160p and 1080p produce the same file —
        // offered raw, the menu lists it three times under three names, two of
        // which are lies. An implementation with no dedupe returns 6 here.
        let options = ExportPreflight.options(from: Self.macScreenEstimates())
        #expect(options.count == 4)
        #expect(options.map(\.resolution) == [.source, .hd720p, .sd540p, .sd480p])
    }

    @Test("The surviving label for a tie is the honest one")
    func tiesKeepTheSourceLabel() {
        // Keeping the LAST of a tie instead of the first is the plausible
        // wrong implementation — it reads as "the most specific label wins" —
        // and it would offer "1080p" for a recording that has no 1080p in it.
        let options = ExportPreflight.options(from: Self.macScreenEstimates())
        #expect(options.first?.resolution == .source,
                "a tie resolved to a resolution the recording never had")
    }

    @Test("A recording larger than a preset still gets the smaller choices")
    func downscalesAreOfferedWhenTheyDiffer() {
        // The guard against over-collapsing: dedupe must key on render SIZE,
        // not on anything cheaper like "is this the source". A 4K recording
        // genuinely differs at every step, so nothing collapses.
        func e(_ r: ExportResolution, _ w: Int, _ h: Int) -> ExportEstimate {
            ExportEstimate(resolution: r, durationSeconds: 10, width: w, height: h,
                           estimatedMaxBytes: 1_000_000, basis: "test")
        }
        let options = ExportPreflight.options(from: [
            e(.source, 5120, 2880), e(.uhd2160p, 3840, 2160), e(.hd1080p, 1920, 1080),
        ])
        #expect(options.count == 3)
    }

    @Test("A degenerate estimate is dropped rather than offered as 0 × 0")
    func zeroSizedEstimatesAreDropped() {
        let good = ExportEstimate(resolution: .source, durationSeconds: 1, width: 100,
                                  height: 50, estimatedMaxBytes: 1000, basis: "t")
        let bad = ExportEstimate(resolution: .hd720p, durationSeconds: 1, width: 0,
                                 height: 0, estimatedMaxBytes: 0, basis: "t")
        #expect(ExportPreflight.options(from: [good, bad]).count == 1)
    }

    @Test("The size is worded as a ceiling, never as an estimate")
    func sizeIsWordedAsACeiling() {
        // `estimatedMaxBytes` is an upper bound the estimator's own doc puts at
        // roughly 4x the real file. "≈20.8 MB" promises an accuracy it does not
        // have and would be wrong every time, in the same direction.
        let label = ExportPreflight.ceiling(bytes: 20_800_000)
        #expect(label.contains("at most"))
        #expect(!label.contains("≈"))
        #expect(!label.lowercased().contains("about"))
    }

    @Test("Megabytes are decimal, matching `snitt estimate` exactly")
    func megabytesMatchTheCLI() {
        // The CLI prints `at most %7.1fMB` over bytes / 1_000_000
        // (snitt-cli/main.swift:362). Dividing by 1_048_576 instead — the
        // plausible wrong implementation, since "MB" is ambiguous — turns this
        // into 19.8 and puts the GUI and the CLI a megabyte apart on the same
        // export.
        #expect(ExportPreflight.ceiling(bytes: 20_800_000) == "at most 20.8 MB")
        #expect(ExportPreflight.ceiling(bytes: 6_400_000) == "at most 6.4 MB")
    }

    @Test("Gigabyte-scale exports stay readable")
    func gigabytesRollOver() {
        #expect(ExportPreflight.ceiling(bytes: 3_200_000_000) == "at most 3.2 GB")
    }

    @Test("A nonsense byte count does not produce a negative size")
    func negativeBytesAreClamped() {
        #expect(ExportPreflight.ceiling(bytes: -1) == "at most 0.0 MB")
    }

    @Test("The menu title carries the label, the pixels and the ceiling")
    func menuTitleIsSelfContained() {
        // A popup item that says only "720p" makes the user open the menu to
        // compare, which is the thing this feature exists to stop.
        let option = ExportOption(resolution: .hd720p, width: 1280, height: 831,
                                  maxBytes: 24_000_000)
        #expect(option.menuTitle == "720p — 1280 × 831, at most 24.0 MB")
    }

    @Test("The default selection preserves what the app did before this menu")
    func defaultIsSource() {
        // Exporting at source is what pressing Export did before the menu
        // existed. Anything else silently changes the output of an unchanged
        // gesture.
        let options = ExportPreflight.options(from: Self.macScreenEstimates())
        #expect(ExportPreflight.defaultSelection(in: options)?.resolution == .source)
        #expect(ExportPreflight.defaultSelection(in: []) == nil)
    }

    @Test("The caveat says the number is a bound, not a prediction")
    func caveatIsHonest() {
        #expect(ExportPreflight.caveat.contains("upper bound"))
        #expect(ExportPreflight.caveat.lowercased().contains("not a prediction"))
    }
}
