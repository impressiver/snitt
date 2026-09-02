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
