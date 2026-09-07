import AppKit
import SnittDocument

/// The scrubbable, trimmable timeline beneath the editor's video surface.
///
/// Holds no rules of its own. `TrimGesture` (SnittDocument) answers every
/// "is this a click or a deliberate drag" question; this view's only job is
/// to convert an `NSEvent`'s location to a time, feed it to `gesture`, and
/// call out through `onScrub`/`onSelect`. §4.7 puts gesture handling in
/// AppKit — not because AppKit is where the rules belong, but because
/// keeping the untestable part (drawing, event plumbing) as small as
/// possible is the only defence available for code no test can see.
///
/// D56 (M5f Task 4): a drag SELECTS; it never touches the EDL. `onSelect`
/// reports the drag's result (a `Selection`, or `nil` for a plain click) to
/// the owner, which decides separately, and later, whether to cut it —
/// see `EditorTimelineState.cutSelection()`. Before this task `onTrim`
/// applied a cut the instant a drag ended, which is the defect D56 exists
/// to fix.
///
/// `TimelineGeometry` (SnittDocument) answers pixel-to-time for DRAWING —
/// the OUTPUT axis, per D56 (M5f Task 3) — but gesture math
/// (`sourceTime(atX:)`) deliberately does NOT go through it: see `duration`'s
/// doc comment below for why interaction stays on its own, fixed SOURCE
/// scale instead.
@MainActor
public final class TimelineView: NSView {
    public var onScrub: (Double) -> Void = { _ in }
    /// Called every time a drag resolves: `Selection(range:)` for a drag
    /// that cleared the pixel threshold, `nil` for a plain click (or a drag
    /// too short to count) — either way, always a REPLACEMENT of whatever
    /// was selected before, never an edit. See this type's doc comment.
    public var onSelect: (Selection?) -> Void = { _ in }

    /// Pixels of mouse wobble a click may exhibit before it counts as a
    /// deliberate selection rather than jitter. This is a PIXEL constant
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
    /// SOURCE time (M5f Task 4) — the last COMMITTED selection, i.e. what a
    /// completed drag reported through `onSelect`. Set locally the instant
    /// a drag ends (for an immediate redraw, with no round trip through the
    /// owner needed for the rectangle to appear) and also mirrored back down
    /// through `update(selection:)`, so the owner clearing it externally
    /// (`EditorTimelineState.cutSelection()`, once a cut is made) redraws
    /// this view without this type needing its own "clear" entry point.
    /// `nil` means no selection — nothing drawn beyond `gesture.previewRange`.
    private var selection: Selection?

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
    /// `duration`/`cuts`/`selection` are SOURCE time; `jumpPoints`/`playhead`
    /// are OUTPUT time. See this type's stored properties of the same names
    /// for why the two halves of this parameter list are deliberately on
    /// different clocks. `selection` defaults to `nil` for callers (existing
    /// tests among them) that don't drive selection at all.
    public func update(duration: Double, cuts: [TimeRange], jumpPoints: [JumpPoint],
                       playhead: Double, selection: Selection? = nil) {
        self.duration = duration
        self.cuts = cuts
        self.jumpPoints = jumpPoints
        self.playhead = playhead
        self.selection = selection
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
        let range = gesture.ended(atTime: time, minimumSeconds: minimumDragSeconds)
        // D56 (M5f Task 4): a resolved drag REPLACES the selection — it
        // never appends a `Cut`. A plain click (nil `range`) clears any
        // prior selection and scrubs, matching the pre-D56 behaviour for
        // clicks exactly; a deliberate drag reports the new selection and,
        // as before this task, does NOT also scrub — its own `mouseDown`
        // already moved the playhead to the drag's start.
        selection = range.map { Selection(range: $0) }
        onSelect(selection)
        if range == nil {
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

        // D56 (M5f Task 4): selecting is not cutting, and is drawn as such —
        // transparent BLUE, not the old orange "about to cut" preview it
        // replaces. The live in-progress drag (`gesture.previewRange`) takes
        // priority over the last COMMITTED selection (`self.selection`), so
        // starting a fresh drag shows only the new range, not both at once;
        // once the drag ends, `previewRange` goes nil and `selection` (set
        // in `mouseUp`) takes over, so the rectangle persists on screen
        // until a new drag replaces it or a cut clears it.
        if let range = gesture.previewRange ?? selection?.range,
           let startX = geometry.x(atSource: SourceTime(range.start)),
           let endX = geometry.x(atSource: SourceTime(range.end)) {
            // Both ends can still fail to map (e.g. a selection sitting over
            // ground an earlier cut already removed) — skipped rather than
            // clamped, so a half-inside-a-cut selection isn't drawn as
            // spanning territory it does not actually cover.
            //
            // Alpha 0.35 is the same value the old orange cut-preview used —
            // already tuned, in this same method, to read clearly over both
            // `controlBackgroundColor` (the view's own fill) and the
            // semi-transparent `tertiaryLabelColor` track without hiding
            // either. Only the hue changes here, from orange to blue; that
            // is what carries the new meaning ("selected, not yet decided")
            // instead of the old one ("about to remove this").
            NSColor.systemBlue.withAlphaComponent(0.35).setFill()
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
