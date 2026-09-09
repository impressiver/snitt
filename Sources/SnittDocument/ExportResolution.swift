// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// The output size an export targets.
///
/// Named by pixels rather than by destination — "1080p", not "Social Media".
/// A destination name ages badly (every platform's limit moves, and none of
/// them is Snitt's to track) and it hides the one fact a caller can actually
/// reason about. An agent fitting an attachment limit needs the number.
///
/// `source` keeps the recording's own dimensions, which on a Retina display is
/// frequently larger than anything the file will be watched at.
public enum ExportResolution: String, Codable, Sendable, CaseIterable {
    case source
    case uhd2160p = "2160p"
    case hd1080p = "1080p"
    case hd720p = "720p"
    case sd540p = "540p"
    case sd480p = "480p"

    /// The long edge in pixels, or nil for `source`.
    public var longEdge: Int? {
        switch self {
        case .source: nil
        case .uhd2160p: 3840
        case .hd1080p: 1920
        case .hd720p: 1280
        case .sd540p: 960
        case .sd480p: 640
        }
    }

    /// Ordered largest first, so a caller walking down to fit a budget walks
    /// in the direction that shrinks.
    public static var descending: [ExportResolution] {
        [.source, .uhd2160p, .hd1080p, .hd720p, .sd540p, .sd480p]
    }
}
