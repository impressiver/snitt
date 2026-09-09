// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import ScreenCaptureKit

/// A target that has already been resolved to a live `SCContentFilter`.
///
/// Both selection paths converge here — the interactive picker and cached
/// re-resolution — so `CaptureSession` never has to know which produced it.
///
/// `@unchecked Sendable` for the same reason `CaptureTarget` is: `SCContentFilter`
/// is not marked `Sendable` by ScreenCaptureKit, but Snitt only reads it after
/// construction and never mutates it.
public struct ResolvedTarget: @unchecked Sendable {
    /// Which path produced this target. Retained because spike S4 (§14) needs
    /// to correlate the monthly re-consent prompt against the paths actually used.
    public enum Provenance: String, Sendable, Equatable {
        case picker
        case cache
    }

    public let filter: SCContentFilter
    public let descriptor: CaptureTargetDescriptor
    /// The durable form, when one exists — displays and windows resolved from
    /// the picker can be re-found later; some picker selections cannot.
    public let reference: TargetReference?
    public let provenance: Provenance

    public init(filter: SCContentFilter,
                descriptor: CaptureTargetDescriptor,
                reference: TargetReference?,
                provenance: Provenance) {
        self.filter = filter
        self.descriptor = descriptor
        self.reference = reference
        self.provenance = provenance
    }
}

extension SCContentFilter {
    /// Capture dimensions in PIXELS.
    ///
    /// `SCStreamConfiguration.width`/`height` are pixel counts, but
    /// `SCWindow.frame` and `SCDisplay.width` are in points. On a Retina display
    /// those differ by the backing scale, so a resolver that reports points
    /// silently configures a half-resolution capture. Deriving the size from the
    /// filter — the one object BOTH resolvers produce — keeps the interactive and
    /// cached paths from disagreeing about how big the same window is.
    ///
    /// Dimensions are rounded down to even numbers because H.264 requires even
    /// width and height.
    var pixelDimensions: (width: Int, height: Int) {
        let scale = CGFloat(pointPixelScale)
        let width = Int(contentRect.width * scale)
        let height = Int(contentRect.height * scale)
        return (width - (width % 2), height - (height % 2))
    }
}
