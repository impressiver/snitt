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

    public private(set) var phase: Phase = .idle

    public init() {}

    public mutating func began(atTime time: Double) {
        phase = .dragging(from: time)
    }

    public mutating func moved(toTime time: Double) {
        guard case .dragging = phase else { return }
        currentTime = time
    }

    /// Ends the drag, returning the range it covered, or `nil` if it was too
    /// short to count as a deliberate cut rather than click jitter.
    ///
    /// `minimumSeconds` is a parameter, not a constant here, deliberately: a
    /// fixed time threshold is wrong in opposite directions depending on
    /// recording length. A hand wobbles by roughly the same number of
    /// *pixels* on any click regardless of what the timeline shows, but the
    /// same pixel count maps to wildly different amounts of media time
    /// depending on how many seconds are squeezed into the view's width — a
    /// ten-minute recording at 800px is ~0.75s/pixel, so a 0.05s threshold
    /// sits under a single pixel and any click becomes a cut; a five-second
    /// recording is ~0.006s/pixel, so the same 0.05s is ~8px and a
    /// deliberate short cut is silently swallowed. Converting a pixel budget
    /// to seconds requires `TimelineGeometry`, which lives with the view —
    /// this type stays free of pixels and AppKit, and the caller (the view)
    /// computes the right threshold for its own current geometry and hands
    /// it in.
    public mutating func ended(atTime time: Double, minimumSeconds: Double) -> TimeRange? {
        guard case .dragging(let from) = phase else { return nil }
        phase = .idle
        currentTime = nil
        let range = Self.normalised(from, time)
        guard range.end - range.start >= minimumSeconds else { return nil }
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
