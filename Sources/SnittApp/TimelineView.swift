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
///
/// D56 (M5f Task 5): a cut draws as a FOLD — its own two edges collapsed to
/// the single OUTPUT position they meet at (`TimelineGeometry.x(atFold:)`),
/// not a gap and not the red overlay Task 3 deleted. Clicking a fold expands
/// it in place; right-clicking one offers Remove Cut. Both are handled ahead
/// of the existing scrub/drag machinery in `mouseDown`/`menu(for:)` — see
/// `foldHit(atX:)` — because a fold draws thin and would otherwise lose
/// every click to the scrub gesture that already claims the whole track.
/// Expansion (`expandedCutIDs`) is UI state exactly like `selection`: it
/// never reaches `edl`, so it cannot change `Timebase.outputDuration` or
/// where the playhead maps — see `EditorTimelineState.expandedCutIDs`'s doc
/// comment for the model-side half of that guarantee.
@MainActor
public final class TimelineView: NSView {
    public var onScrub: (Double) -> Void = { _ in }
    /// Called every time a drag resolves: `Selection(range:)` for a drag
    /// that cleared the pixel threshold, `nil` for a plain click (or a drag
    /// too short to count) — either way, always a REPLACEMENT of whatever
    /// was selected before, never an edit. See this type's doc comment.
    public var onSelect: (Selection?) -> Void = { _ in }
    /// A fold was clicked (`foldHit(atX:)`) and should toggle between
    /// collapsed and expanded — the owner (`EditorTimelineState`) holds the
    /// actual `expandedCutIDs` set and hands it back down through `update`,
    /// exactly as `selection` round-trips; this view never tracks expansion
    /// on its own.
    public var onToggleExpansion: (UUID) -> Void = { _ in }
    /// Right-click ▸ Remove Cut on a fold. Unlike `onToggleExpansion`, this
    /// IS an edit — the owner turns it into an undoable, persisted removal
    /// from `edl.cuts` (`EditorTimelineState.removeCut(id:)`).
    public var onRemoveCut: (UUID) -> Void = { _ in }

    /// Pixels of mouse wobble a click may exhibit before it counts as a
    /// deliberate selection rather than jitter. This is a PIXEL constant
    /// deliberately: a hand wobbles by roughly the same number of pixels on
    /// any click regardless of what the timeline shows. Converting it to a
    /// number of seconds requires knowing how much SOURCE media time is
    /// packed into this view's current width — see `minimumDragSeconds` and
    /// `sourceTime(atX:)`. `TrimGesture` itself never sees pixels; it takes
    /// the converted threshold as a parameter to `ended(atTime:minimumSeconds:)`.
    private static let minimumDragPixels: Double = 3.0

    /// Pixels of slop a click gets around a fold's own line (drawn just 2px
    /// wide, see `draw`) before it counts as "aimed at this fold" rather
    /// than the surrounding scrub track. Wider than `minimumDragPixels`
    /// deliberately: that constant absorbs a hand's wobble on an otherwise
    /// enormous target (the whole track); this one is the target itself,
    /// and a fold nobody can reliably click is a fold nobody can expand.
    ///
    /// Trap 2 (Task 5 dispatch): without a deliberate hit-test here,
    /// `mouseDown`'s pre-existing scrub/drag logic runs for EVERY mouse-down
    /// on the track — a fold is thin, so it would lose every click to a
    /// scrub, exactly the ambiguity Task 4 already fixed one interaction
    /// earlier for drag-vs-cut.
    private static let foldHitMarginPixels: Double = 6.0

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
    /// SOURCE-time cuts, WITH identity — `edl.cuts` exactly as the owner
    /// already has them. Feeds `rebuildGeometry`'s `Timebase`; unlike before
    /// Task 5, a `Cut`'s `id` matters here as much as its `range` does:
    /// `foldHit(atX:)` reports it back through `onToggleExpansion`/
    /// `onRemoveCut`, and both need to name WHICH cut a click landed on, not
    /// merely that some cut did. Drawing a filled rect FOR a cut's REMOVED
    /// span is still gone (see `draw`), since a cut has no position on the
    /// output axis to draw one at — what draws now is its FOLD.
    private var cuts: [Cut] = []
    /// The folds currently expanded, by `Cut.id` — round-tripped from
    /// `EditorTimelineState.expandedCutIDs` exactly as `selection` is: this
    /// view never decides expansion on its own, only reports a click via
    /// `onToggleExpansion` and draws whatever the owner hands back.
    private var expandedCutIDs: Set<UUID> = []
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

    /// Set by `mouseDown` when the press landed on a fold (`foldHit(atX:)`),
    /// so `mouseDragged`/`mouseUp` skip the scrub/selection machinery
    /// entirely for the rest of THIS press. Without this, `mouseUp` (which
    /// has no idea `mouseDown` already resolved the click as a fold toggle)
    /// would see `gesture.ended` return `nil` — no drag was ever begun — and
    /// treat that exactly like a plain click: clearing `selection` via
    /// `onSelect(nil)` and reissuing a scrub to wherever the fold happened
    /// to sit. A fold click must not ALSO silently discard whatever was
    /// selected or move the playhead.
    private var activeFoldClick: UUID?

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
    /// different clocks. `selection` defaults to `nil`, and `expandedCutIDs`
    /// to empty, for callers (existing tests among them) that don't drive
    /// them at all.
    public func update(duration: Double, cuts: [Cut], jumpPoints: [JumpPoint],
                       playhead: Double, selection: Selection? = nil,
                       expandedCutIDs: Set<UUID> = []) {
        self.duration = duration
        self.cuts = cuts
        self.jumpPoints = jumpPoints
        self.playhead = playhead
        self.selection = selection
        self.expandedCutIDs = expandedCutIDs
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
    /// `Timebase`'s conversions (Task 1) — but, since Task 5, WITH each
    /// `Cut`'s own `id` preserved rather than re-minted: `geometry.x(atFold:)`
    /// and `foldHit(atX:)` both need to name a specific cut, and a fresh
    /// `Cut(range:)` per call would silently hand back a different id than
    /// the one `edl.cuts` (and `EditorTimelineState.expandedCutIDs`) actually
    /// use.
    private func rebuildGeometry() {
        let edl = EditDecisionList(cuts: cuts)
        geometry = TimelineGeometry(width: bounds.width, timebase: Timebase(sourceDuration: duration, edl: edl))
    }

    /// The pixel width an EXPANDED fold draws at: `cut`'s own SOURCE length,
    /// converted at the OUTPUT timeline's own pixels-per-second
    /// (`geometry.width / geometry.duration`) — the same scale every kept
    /// second on this view already draws at — so the revealed footage reads
    /// at a size consistent with everything around it, not an arbitrary
    /// fixed box. Also doubles as the expanded fold's HIT-TEST width (see
    /// `foldHit(atX:)`): the whole widened rect is the target once expanded,
    /// not just its edge. `geometry.duration` is the OUTPUT duration
    /// (Task 3); zero (nothing kept, or zero view width) has no scale to
    /// borrow, so this returns 0 rather than dividing by it.
    private func expandedWidthPixels(for cut: Cut) -> Double {
        guard geometry.duration > 0, bounds.width > 0 else { return 0 }
        let cutLength = cut.range.end - cut.range.start
        return cutLength / geometry.duration * bounds.width
    }

    /// The `Cut` whose fold `x` lands in/near, or `nil` if `x` is plain
    /// scrub/drag territory. A COLLAPSED fold is a `foldHitMarginPixels`
    /// window either side of its single line; an EXPANDED one is its whole
    /// widened rect (`expandedWidthPixels`), since that entire rect IS the
    /// revealed cut once expanded. Checked before any drag/scrub logic runs
    /// (`mouseDown`, `menu(for:)`) — see this type's own doc comment and
    /// `foldHitMarginPixels` for why a fold needs its own dedicated hit-test
    /// rather than falling through to the track's.
    private func foldHit(atX x: Double) -> Cut? {
        // A degenerate geometry (zero width, or zero OUTPUT duration —
        // everything cut away) has no real fold positions: `geometry.x
        // (atFold:)` falls back to 0 for every cut in that case (see
        // `TimelineGeometry.isDegenerate`), which would otherwise make
        // every cut look like a fold sitting exactly at the origin and
        // swallow a click aimed at nothing in particular — found by
        // `TimelineViewTests.zeroWidthViewIsFinite`, an existing test whose
        // click at x=0 landed on this false "fold" instead of scrubbing
        // the instant this guard was missing.
        guard bounds.width > 0, geometry.duration > 0 else { return nil }
        for cut in cuts {
            let foldX = geometry.x(atFold: cut)
            if expandedCutIDs.contains(cut.id) {
                let width = expandedWidthPixels(for: cut)
                if x >= foldX, x <= foldX + width { return cut }
            } else if abs(x - foldX) <= Self.foldHitMarginPixels {
                return cut
            }
        }
        return nil
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
        let point = convert(event.locationInWindow, from: nil)
        // D56 (M5f Task 5), Trap 2: checked BEFORE any scrub/drag logic
        // runs. A fold click never begins a gesture and never scrubs — see
        // `activeFoldClick`'s doc comment for why `mouseDragged`/`mouseUp`
        // also need to know this happened.
        if let cut = foldHit(atX: point.x) {
            activeFoldClick = cut.id
            onToggleExpansion(cut.id)
            needsDisplay = true
            return
        }
        activeFoldClick = nil
        let time = time(for: event)
        gesture.began(atTime: time)
        onScrub(time)
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard activeFoldClick == nil else { return }
        gesture.moved(toTime: time(for: event))
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        if activeFoldClick != nil {
            // The press already resolved in `mouseDown` (a fold toggled) —
            // no gesture was begun, so falling through to the normal
            // plain-click path below would misread that as a click that
            // scrubs and clears `selection`. See `activeFoldClick`'s doc
            // comment.
            activeFoldClick = nil
            return
        }
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

    /// AppKit's right-click entry point: returning `nil` suppresses any
    /// context menu (the default off a fold), a non-nil menu shows it.
    /// D56 (M5f Task 5): "right-clicking [a fold] offers Remove Cut". Reuses
    /// `foldHit(atX:)` — the same hit-test `mouseDown` uses — so left- and
    /// right-click agree on exactly what counts as "on a fold".
    public override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let cut = foldHit(atX: point.x) else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Remove Cut",
                              action: #selector(handleRemoveCutMenuItem(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = cut.id
        menu.addItem(item)
        return menu
    }

    /// Not `private`: a test seam, exactly like `EditorWindowController`'s
    /// `...ForTesting` methods — driving a real `NSMenu`'s target-action
    /// dispatch needs a live `NSApp`/window this test target cannot assume,
    /// so a test instead calls this directly with the same `NSMenuItem`
    /// `menu(for:)` would have built.
    @objc func handleRemoveCutMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onRemoveCut(id)
    }

    // MARK: - Drawing (appearance only — deliberately untested, see Task 6 brief)

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()

        let trackRect = NSRect(x: 0, y: bounds.height * 0.35,
                               width: bounds.width, height: bounds.height * 0.3)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(rect: trackRect).fill()

        // D56 (M5f Task 5): a cut is a FOLD — its own two edges, collapsed
        // to the single OUTPUT position they meet at (`geometry.x(atFold:)`),
        // drawn as a thin red line — not a gap, and not the red OVERLAY
        // patch Task 3 deleted (which drew a cut's REMOVED span as if it
        // still occupied space on this axis; a fold draws only the single
        // point the removal collapsed to). An EXPANDED fold
        // (`expandedCutIDs`, toggled by `foldHit` in `mouseDown`) widens
        // that line into a transparent red rect sized to the cut's own
        // SOURCE length (`expandedWidthPixels`) — "showing the folded
        // segment" — at the same pixels-per-second the rest of this
        // (output) timeline already draws at. Content drawn after a fold is
        // deliberately NOT pushed right to make room for it: this is
        // appearance only (see this method's own doc comment), and the
        // property this task actually guarantees is that NOTHING here can
        // move `geometry` itself, not that every later pixel re-flows
        // around a widened fold — see `EditorTimelineState.expandedCutIDs`.
        for cut in cuts {
            let foldX = geometry.x(atFold: cut)
            if expandedCutIDs.contains(cut.id) {
                let width = expandedWidthPixels(for: cut)
                NSColor.systemRed.withAlphaComponent(0.35).setFill()
                NSBezierPath(rect: NSRect(x: foldX, y: 0, width: width,
                                          height: bounds.height)).fill()
            } else {
                NSColor.systemRed.setFill()
                NSBezierPath(rect: NSRect(x: foldX - 1, y: 0, width: 2,
                                          height: bounds.height)).fill()
            }
        }

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
