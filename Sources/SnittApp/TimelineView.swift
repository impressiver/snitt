import AppKit
import SnittDocument

/// The scrubbable, trimmable timeline beneath the editor's video surface.
///
/// Holds no rules of its own. `TrimGesture` (SnittDocument) answers every
/// "is this a click or a cut" question; this view's only job is to convert
/// an `NSEvent`'s location to a time, feed it to `gesture`, and call out
/// through `onScrub`/`onTrim`. §4.7 puts gesture handling in AppKit — not
/// because AppKit is where the rules belong, but because keeping the
/// untestable part (drawing, event plumbing) as small as possible is the
/// only defence available for code no test can see.
///
/// `TimelineGeometry` (SnittDocument) answers pixel-to-time for DRAWING —
/// the OUTPUT axis, per D56 (M5f Task 3) — but gesture math
/// (`sourceTime(atX:)`) deliberately does NOT go through it: see `duration`'s
/// doc comment below for why interaction stays on its own, fixed SOURCE
/// scale instead.
@MainActor
public final class TimelineView: NSView {
    public var onScrub: (Double) -> Void = { _ in }
    public var onTrim: (TimeRange) -> Void = { _ in }

    /// Pixels of mouse wobble a click may exhibit before it counts as a
    /// deliberate trim rather than jitter. This is a PIXEL constant
    /// deliberately: a hand wobbles by roughly the same number of pixels on
    /// any click regardless of what the timeline shows. Converting it to a
    /// number of seconds requires knowing how much SOURCE media time is
    /// packed into this view's current width — see `minimumDragSeconds` and
    /// `sourceTime(atX:)`. `TrimGesture` itself never sees pixels; it takes
    /// the converted threshold as a parameter to `ended(atTime:minimumSeconds:)`.
    private static let minimumDragPixels: Double = 3.0

    /// D56 (M5f Task 3): draws on the OUTPUT (export) axis, built fresh from
    /// `duration`/`cuts` on every `update`/`layout` — see `rebuildGeometry`.
    private var geometry = TimelineGeometry(
        width: 0, timebase: Timebase(sourceDuration: 0, edl: EditDecisionList()))
    private var gesture = TrimGesture()

    /// SOURCE duration — deliberately NOT re-derived from `geometry.duration`
    /// (the OUTPUT duration). `time(for:)`/`minimumDragSeconds` fix their
    /// scale to this directly and never to `geometry`, so a drag's meaning
    /// does not shift as cuts are applied mid-session (M4b whole-branch
    /// review, Critical finding #1: a view whose pixel-to-time scale shrinks
    /// with every cut makes the SAME pixel range mean a different source
    /// span on the second drag, landing inside the region a prior cut
    /// already removed instead of a fresh one).
    private var duration: Double = 0
    /// SOURCE-time cut ranges — `edl.cuts` as the owner already has them.
    /// Feeds `rebuildGeometry`'s `Timebase`; drawing a rect FOR a cut is
    /// gone (see `draw`), since a cut has no position on the output axis to
    /// draw one at.
    private var cuts: [TimeRange] = []
    /// OUTPUT time (M5f Task 3) — see `EditorTimelineState.displayState`'s
    /// doc comment for why these arrive unconverted.
    private var jumpPoints: [JumpPoint] = []
    /// OUTPUT time (M5f Task 3) — `PreviewController`'s player plays the
    /// composition `CompositionBuilder` built from kept ranges only, so its
    /// `currentTime()` already IS output time before it ever reaches here.
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
    ///
    /// `duration`/`cuts` are SOURCE time; `jumpPoints`/`playhead` are OUTPUT
    /// time. See this type's stored properties of the same names for why the
    /// two halves of this parameter list are deliberately on different
    /// clocks.
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

    /// Builds the OUTPUT-time geometry `draw()` positions the playhead and
    /// jump points against — D56's first requirement: the timeline reflects
    /// what will actually export, not `capture.mov`'s own length. `cuts`
    /// folds into a throwaway `EditDecisionList` purely to reach
    /// `Timebase`'s conversions (Task 1); nothing about a `Cut`'s identity
    /// matters to this drawing-only geometry.
    private func rebuildGeometry() {
        let edl = EditDecisionList(cuts: cuts.map { Cut(range: $0) })
        geometry = TimelineGeometry(width: bounds.width, timebase: Timebase(sourceDuration: duration, edl: edl))
    }

    /// Maps a pixel to SOURCE time using a scale fixed to the recording's
    /// own (uncut) length — deliberately never routed through `geometry`,
    /// which shrinks the same width to a smaller apparent duration as cuts
    /// land. See `duration`'s doc comment for why interaction must stay off
    /// that shrinking axis.
    private func sourceTime(atX x: Double) -> Double {
        guard bounds.width > 0, duration > 0 else { return 0 }
        return min(max(x / bounds.width * duration, 0), duration)
    }

    /// The pixel budget above, converted at the FIXED source scale.
    /// `sourceTime(atX:)` is clamped and NaN-free even at zero width (it
    /// returns 0 there), so this is always a finite, non-negative number of
    /// seconds.
    private var minimumDragSeconds: Double {
        sourceTime(atX: Self.minimumDragPixels) - sourceTime(atX: 0)
    }

    private func time(for event: NSEvent) -> Double {
        let point = convert(event.locationInWindow, from: nil)
        return sourceTime(atX: point.x)
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

        // No red patch for a cut anymore (D56): `geometry` now draws on the
        // OUTPUT axis, where a cut has no position at all — it is not part
        // of the export, so there is nothing here to fill a rect over.
        // Marking cut BOUNDARIES on the kept content is Task 6's to add.

        if let preview = gesture.previewRange,
           let startX = geometry.x(atSource: SourceTime(preview.start)),
           let endX = geometry.x(atSource: SourceTime(preview.end)) {
            // Both ends of an in-progress drag can still fail to map (e.g.
            // dragging back over ground an earlier cut already removed) —
            // skipped rather than clamped, so a half-inside-a-cut drag isn't
            // drawn as spanning territory it does not actually cover.
            NSColor.systemOrange.withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: NSRect(x: startX, y: 0, width: endX - startX,
                                      height: bounds.height)).fill()
        }

        NSColor.systemYellow.setFill()
        for point in jumpPoints {
            let x = geometry.x(atOutput: OutputTime(point.timeSeconds))
            NSBezierPath(rect: NSRect(x: x - 1, y: 0, width: 2, height: bounds.height)).fill()
        }

        NSColor.labelColor.setFill()
        let playheadX = geometry.x(atOutput: OutputTime(playhead))
        NSBezierPath(rect: NSRect(x: playheadX - 1, y: 0, width: 2, height: bounds.height)).fill()
    }
}
