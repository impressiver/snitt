import Foundation

/// Maps between timeline pixels and media seconds.
///
/// Pure and in `SnittDocument` deliberately: this is the arithmetic every
/// timeline interaction depends on, and the only part of the timeline
/// testable without a window or a mouse. The `NSView` draws and forwards
/// events; the rules live here.
public struct TimelineGeometry: Equatable, Sendable {
    public let width: Double
    public let duration: Double

    public init(width: Double, duration: Double) {
        self.width = width
        self.duration = duration
    }

    /// Zero width or zero duration would divide to NaN, and a NaN reaching a
    /// drawing call is silent garbage on screen rather than a crash. A view
    /// is laid out at zero width before its first real layout pass, so this
    /// is reachable on every launch, not a theoretical edge.
    private var isDegenerate: Bool { width <= 0 || duration <= 0 }

    public func time(atX x: Double) -> Double {
        guard !isDegenerate else { return 0 }
        return min(max(x / width * duration, 0), duration)
    }

    public func x(atTime time: Double) -> Double {
        guard !isDegenerate else { return 0 }
        return min(max(time / duration * width, 0), width)
    }

    public func cutRects(_ cuts: [TimeRange]) -> [(x: Double, width: Double)] {
        cuts.map { cut in
            let start = x(atTime: cut.start)
            // The SPAN, not the end coordinate — those differ the moment the
            // start clamps.
            return (x: start, width: x(atTime: cut.end) - start)
        }
    }
}
