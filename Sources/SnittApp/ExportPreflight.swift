// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittDocument

/// One row of the export menu: a resolution worth offering, what it renders
/// at, and the ceiling on what it will weigh.
public struct ExportOption: Equatable, Sendable {
    public let resolution: ExportResolution
    public let width: Int
    public let height: Int
    public let maxBytes: Int

    public init(resolution: ExportResolution, width: Int, height: Int, maxBytes: Int) {
        self.resolution = resolution
        self.width = width
        self.height = height
        self.maxBytes = maxBytes
    }

    public var pixels: String { "\(width) × \(height)" }
    public var ceiling: String { ExportPreflight.ceiling(bytes: maxBytes) }
}

/// Turning `ExportEstimator`'s answers into a menu a person can pick from.
///
/// Pure, and separate from the panel that shows it, for the reason every other
/// model in this project is: the interesting decisions here are arithmetic and
/// wording, and neither needs a sheet to be wrong.
public enum ExportPreflight {

    /// The resolutions actually worth offering, largest first.
    ///
    /// **Deduplicated by render size, and that is the whole point.** A preset
    /// never enlarges — `ExportEstimator.renderSize` caps the composition to
    /// the preset's long edge and returns it unchanged when it already fits —
    /// so on a typical Mac screen recording at 1512×982, `source`, `2160p` and
    /// `1080p` all render 1512×982. Offered raw, the menu lists one identical
    /// file three times under three names, two of which are false: there is no
    /// 2160p in a 1512-wide recording.
    ///
    /// Ties keep the FIRST entry, and `ExportResolution.descending` leads with
    /// `.source`, so the surviving label is the honest one — "this recording,
    /// as it is" rather than a resolution it never had.
    public static func options(from estimates: [ExportEstimate]) -> [ExportOption] {
        var seen = Set<String>()
        var out: [ExportOption] = []
        for estimate in estimates {
            // Guard against a degenerate estimate rather than rendering
            // "0 × 0" as a choice: a caller can hand us whatever the
            // estimator produced, including for a composition that failed
            // to build.
            guard estimate.width > 0, estimate.height > 0 else { continue }
            guard seen.insert("\(estimate.width)x\(estimate.height)").inserted else { continue }
            out.append(ExportOption(resolution: estimate.resolution,
                                    width: estimate.width,
                                    height: estimate.height,
                                    maxBytes: estimate.estimatedMaxBytes))
        }
        return out
    }

    /// "at most 20.8 MB".
    ///
    /// **"at most", never "≈".** `estimatedMaxBytes` is an upper bound, not a
    /// prediction — `ExportEstimator`'s own doc puts the real file at roughly a
    /// quarter of it on a 5K recording, and says in as many words to use it for
    /// choosing between resolutions rather than predicting a byte count. A "≈"
    /// would promise an accuracy the number does not have.
    ///
    /// Decimal megabytes and one decimal place, matching `snitt estimate`
    /// verbatim (`"at most %7.1fMB"`, `snitt-cli/main.swift:362`) so the CLI,
    /// the MCP tool and this menu describe the same export the same way.
    /// `String(format:)` without a locale is POSIX, so the separator does not
    /// move with the user's region.
    public static func ceiling(bytes: Int) -> String {
        let mb = Double(max(0, bytes)) / 1_000_000
        // Past a thousand megabytes the CLI's format stops being readable
        // ("at most 3200.0 MB"); this is the one place the GUI says more than
        // the CLI does, and it says the same number.
        if mb >= 1000 { return String(format: "at most %.1f GB", mb / 1000) }
        return String(format: "at most %.1f MB", mb)
    }

    /// Said next to the numbers, because a ceiling presented bare reads as a
    /// prediction and will be wrong every time in the same direction.
    public static let caveat =
        "Sizes are an upper bound from AVFoundation, not a prediction — "
        + "real files come in well under. Use them to choose a resolution."

    /// Which row starts selected: the first, which is the source resolution
    /// whenever the estimator could describe it. Exporting at source is what
    /// this app did before this menu existed, so the default changes nothing
    /// for someone who opens the panel and presses Export.
    public static func defaultSelection(in options: [ExportOption]) -> ExportOption? {
        options.first
    }
}
