import AppKit
import SnittDocument

/// The scrubbable, trimmable timeline beneath the editor's video surface.
///
/// Holds no rules of its own. `TimelineGeometry` (SnittDocument) answers
/// every pixel-to-time question and `TrimGesture` (SnittDocument) answers
/// every "is this a click or a cut" question; this view's only job is to
/// convert an `NSEvent`'s location to a time through `geometry`, feed it to
/// `gesture`, and call out through `onScrub`/`onTrim`. §4.7 puts gesture
/// handling in AppKit — not because AppKit is where the rules belong, but
/// because keeping the untestable part (drawing, event plumbing) as small as
/// possible is the only defence available for code no test can see.
@MainActor
public final class TimelineView: NSView {
    public var onScrub: (Double) -> Void = { _ in }
    public var onTrim: (TimeRange) -> Void = { _ in }

    /// Pixels of mouse wobble a click may exhibit before it counts as a
    /// deliberate trim rather than jitter. This is a PIXEL constant
    /// deliberately: a hand wobbles by roughly the same number of pixels on
    /// any click regardless of what the timeline shows. Converting it to a
    /// number of seconds requires knowing how much media time is packed into
    /// this view's current width, which only `geometry` (rebuilt on every
    /// `update` and every `layout`) can answer — see `minimumDragSeconds`.
    /// `TrimGesture` itself never sees pixels; it takes the converted
    /// threshold as a parameter to `ended(atTime:minimumSeconds:)`.
    private static let minimumDragPixels: Double = 3.0

    private var geometry = TimelineGeometry(width: 0, duration: 0)
    private var gesture = TrimGesture()

    private var duration: Double = 0
    private var cuts: [TimeRange] = []
    private var jumpPoints: [JumpPoint] = []
    private var playhead: Double = 0

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        rebuildGeometry()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("TimelineView is not loaded from a nib") }

    public override var isFlipped: Bool { true }

    /// Replaces everything the view draws and recomputes `geometry` for the
    /// bounds it has right now. Called by the owner whenever the underlying
    /// EDL, markers or playback position change.
    public func update(duration: Double, cuts: [TimeRange], jumpPoints: [JumpPoint],
                       playhead: Double) {
        self.duration = duration
        self.cuts = cuts
        self.jumpPoints = jumpPoints
        self.playhead = playhead
        rebuildGeometry()
        needsDisplay = true
    }

    public override func layout() {
        super.layout()
        rebuildGeometry()
        needsDisplay = true
    }

    private func rebuildGeometry() {
        geometry = TimelineGeometry(width: bounds.width, duration: duration)
    }

    /// The pixel budget above, converted through the CURRENT geometry.
    /// `time(atX:)` is clamped and NaN-free even at zero width (it returns 0
    /// there), so this is always a finite, non-negative number of seconds.
    private var minimumDragSeconds: Double {
        geometry.time(atX: Self.minimumDragPixels) - geometry.time(atX: 0)
    }

    private func time(for event: NSEvent) -> Double {
        let point = convert(event.locationInWindow, from: nil)
        return geometry.time(atX: point.x)
    }

    // MARK: - Mouse handling

    public override func mouseDown(with event: NSEvent) {
        let time = time(for: event)
        gesture.began(atTime: time)
        onScrub(time)
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        gesture.moved(toTime: time(for: event))
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        let time = time(for: event)
        if let range = gesture.ended(atTime: time, minimumSeconds: minimumDragSeconds) {
            onTrim(range)
        } else {
            onScrub(time)
        }
        needsDisplay = true
    }

    // MARK: - Drawing (appearance only — deliberately untested, see Task 6 brief)

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()

        let trackRect = NSRect(x: 0, y: bounds.height * 0.35,
                               width: bounds.width, height: bounds.height * 0.3)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(rect: trackRect).fill()

        NSColor.systemRed.withAlphaComponent(0.55).setFill()
        for rect in geometry.cutRects(cuts) {
            NSBezierPath(rect: NSRect(x: rect.x, y: 0, width: rect.width,
                                      height: bounds.height)).fill()
        }

        if let preview = gesture.previewRange {
            NSColor.systemOrange.withAlphaComponent(0.35).setFill()
            for rect in geometry.cutRects([preview]) {
                NSBezierPath(rect: NSRect(x: rect.x, y: 0, width: rect.width,
                                          height: bounds.height)).fill()
            }
        }

        NSColor.systemYellow.setFill()
        for point in jumpPoints {
            let x = geometry.x(atTime: point.timeSeconds)
            NSBezierPath(rect: NSRect(x: x - 1, y: 0, width: 2, height: bounds.height)).fill()
        }

        NSColor.labelColor.setFill()
        let playheadX = geometry.x(atTime: playhead)
        NSBezierPath(rect: NSRect(x: playheadX - 1, y: 0, width: 2, height: bounds.height)).fill()
    }
}
