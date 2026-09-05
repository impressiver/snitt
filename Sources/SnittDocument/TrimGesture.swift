import Foundation

/// Drag-to-trim as a pure state machine.
///
/// Kept in `SnittDocument`, importing only Foundation, so the interesting
/// cases — a drag that ends where it started, a drag backwards, a drag that
/// never began — are five ordinary value-type tests with no window, no run
/// loop, no mouse. The `NSView` forwards mouse events into `began`/`moved`/
/// `ended`; the rules live here.
public struct TrimGesture: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case dragging(from: Double)
    }

    /// The line between a click and a cut, in seconds of media time.
    ///
    /// A user's hand moves a pixel or two on any click, so zero is not the
    /// right threshold — that would turn every click-to-seek into a
    /// zero-length cut in the EDL. 50ms is small enough that no deliberate
    /// short cut is likely to fall under it, while comfortably absorbing
    /// click jitter.
    ///
    /// This is a time-based threshold, and that is a real limitation: the
    /// gesture only sees media time, but the jitter that produces it is
    /// pixel-based and happens at the view. A one-hour recording maps far
    /// more seconds per pixel than a ten-second one, so a fixed time
    /// threshold is more permissive of "clicks" on long recordings and
    /// stricter on short ones — the opposite of what pixel jitter would
    /// suggest. The more correct shape is a pixel threshold decided by the
    /// view (which knows `TimelineGeometry`) and converted to seconds there
    /// before being compared, or passed into this type. Kept as a fixed
    /// time constant here to keep the state machine free of `TimelineGeometry`
    /// and AppKit; revisit if short recordings prove this too permissive in
    /// practice.
    static let minimumDragSeconds: Double = 0.05

    public private(set) var phase: Phase = .idle

    public init() {}

    public mutating func began(atTime time: Double) {
        phase = .dragging(from: time)
    }

    public mutating func moved(toTime time: Double) {
        guard case .dragging = phase else { return }
        currentTime = time
    }

    public mutating func ended(atTime time: Double) -> TimeRange? {
        guard case .dragging(let from) = phase else { return nil }
        phase = .idle
        currentTime = nil
        let range = Self.normalised(from, time)
        guard range.end - range.start >= Self.minimumDragSeconds else { return nil }
        return range
    }

    /// The range the drag would cut if it ended now. Available while
    /// `phase` is `.dragging`, so the view can draw the pending cut before
    /// the mouse is released — a preview that only appeared after `ended`
    /// would be a preview of nothing.
    public var previewRange: TimeRange? {
        guard case .dragging(let from) = phase, let current = currentTime else { return nil }
        return Self.normalised(from, current)
    }

    /// Tracks the most recent `moved` position, separate from `phase.from`,
    /// so the origin of the drag and its current point are both retained.
    private var currentTime: Double?

    private static func normalised(_ a: Double, _ b: Double) -> TimeRange {
        a <= b ? TimeRange(start: a, end: b) : TimeRange(start: b, end: a)
    }
}
