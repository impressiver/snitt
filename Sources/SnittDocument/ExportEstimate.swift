// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

// Lives here, not beside `ExportEstimator`, for the same reason `CropRect` and
// `DeepTrimCriteria` do: it travels over the automation protocol, and
// `SnittAutomation` depends on this module and not on SnittExport. The
// estimator that PRODUCES it needs AVFoundation and stays where it was.

/// What an export would produce, answered before doing it.
///
/// Duration and dimensions are FACTS — they fall out of the EDL and the
/// crop/scale arithmetic and are exactly what the export will produce. The size
/// is an UPPER BOUND, and is named that way rather than dressed up as a
/// prediction: a number that reads as authoritative is one a caller will plan
/// an attachment limit around.
public struct ExportEstimate: Codable, Sendable, Equatable {
    /// Which resolution this estimate describes.
    public var resolution: ExportResolution
    /// Exact: the kept material's duration.
    public var durationSeconds: Double
    /// Exact: the render size, from crop and scale.
    public var width: Int
    public var height: Int
    /// An upper bound, measured. The real file has consistently come in under
    /// this — see `basis` for how it was arrived at.
    public var estimatedMaxBytes: Int
    public var basis: String

    public init(resolution: ExportResolution, durationSeconds: Double,
                width: Int, height: Int, estimatedMaxBytes: Int, basis: String) {
        self.resolution = resolution
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.estimatedMaxBytes = estimatedMaxBytes
        self.basis = basis
    }
}
