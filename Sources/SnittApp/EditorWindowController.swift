import AppKit
import Combine
import SnittCapture
import SnittDocument
import SnittExport
import SwiftUI
import UniformTypeIdentifiers

/// Owns the mutable editing state the timeline drives: the EDL a trim
/// appends a cut to, and the events a trim's re-apply must keep passing.
///
/// `PreviewController.apply(edl:events:)`'s `events` is required (M4b
/// whole-branch review, Important finding #3) — passing `[]` recomputes jump
/// points to empty rather than keeping stale ones (stale markers are a
/// silent §9 divergence, an empty scrub bar is a visible one). This type
/// exists so that every trim keeps passing the recording's real events
/// instead of silently losing every marker.
///
/// Not `private`: `@testable import SnittApp` needs to drive `onTrim` and
/// read `displayState(playhead:)` directly to verify the M4b Critical
/// finding — that a SECOND trim in one session removes a distinct region —
/// without a live `NSWindow` or SwiftUI's runtime.
@MainActor
final class EditorTimelineState: ObservableObject {
    let controller: PreviewController
    let events: [LoggedEvent]
    @Published var edl: EditDecisionList

    /// The window's `UndoManager` (Task 7), set once the window exists —
    /// this type is constructed before the `NSWindow` that owns it. Task
    /// 1's Edit menu already wires `undo:`/`redo:` to the responder chain;
    /// registering against the window's own manager, rather than a private
    /// one, is what makes those menu items resolve to something instead of
    /// nothing.
    weak var undoManager: UndoManager?

    /// The TAIL of the autosave chain: every save awaits the one before it,
    /// so awaiting this one awaits all of them (whole-branch review F2).
    ///
    /// This used to be "the most recent save", overwritten on every trim and
    /// never awaited or cancelled — two trims inside one compositor-build
    /// window ran concurrently, and if the OLDER one's `persist` landed last
    /// the disk kept one cut while the screen showed two. Chaining is what
    /// makes the last write the latest state rather than the slowest task's
    /// state; `EditorPersistenceTests.laterTrimIsNotOverwrittenByAnEarlierSave`
    /// is the test that walks into that inversion deliberately.
    private var pendingSaveTask: Task<Void, Never>?

    /// Saves enqueued but not yet finished. Read at termination (F9): ⌘Q
    /// immediately after a trim must not exit before that trim is on disk.
    private(set) var outstandingSaves = 0

    /// The last EDL that both APPLIED and PERSISTED — the state on disk, and
    /// the state the preview is actually showing. A rejected edit reverts
    /// to this rather than leaving the screen claiming a change that never
    /// reached the file.
    private var lastSavedEDL: EditDecisionList

    /// Called when the compositor refuses an edit, so the window can tell
    /// the user. A refused trim that merely skips the write still leaves a
    /// silent no-op in front of a person who just dragged across the
    /// timeline (whole-branch review F1).
    var onEditRejected: ((Error) -> Void)?

    init(controller: PreviewController, edl: EditDecisionList, events: [LoggedEvent]) {
        self.controller = controller
        self.edl = edl
        self.lastSavedEDL = edl
        self.events = events
    }

    /// Everything `TimelineView` needs. `duration`/`cuts` stay on the SOURCE
    /// clock: `edl.cuts` are already source-time ranges, and the view's own
    /// interaction (dragging out a new cut) must keep computing against the
    /// recording's FULL, unchanging length regardless of what has already
    /// been cut (M4b whole-branch review, Critical finding #1 — feeding the
    /// view a duration that shrinks as cuts land makes a later drag's pixel
    /// range mean a different span each time, walking straight back into
    /// the region a prior cut already removed).
    ///
    /// `jumpPoints`/`playhead`, by contrast, are OUTPUT time, UNCONVERTED
    /// (M5f Task 3): `TimelineGeometry` now draws on the export's own axis
    /// (D56's first requirement — a cut shortens the timeline instead of
    /// leaving a red patch in it), and `controller.player.currentTime()` /
    /// `controller.jumpPoints` are ALREADY exactly that clock —
    /// `CompositionBuilder` only ever builds kept ranges into the
    /// composition. Converting them to source time here, as this method did
    /// before Task 3, was correct while the view drew on the source axis and
    /// is BACKWARDS now that it draws on the output axis: it would hand
    /// `TimelineView` a source-time value for a mapping function that
    /// expects output time, silently landing the playhead and every marker
    /// on the wrong pixel the moment anything has been cut — precisely the
    /// clock confusion this milestone exists to prevent.
    struct DisplayState {
        let duration: Double
        let cuts: [TimeRange]
        let jumpPoints: [JumpPoint]
        let playhead: Double
    }

    func displayState(playhead outputPlayhead: Double) -> DisplayState {
        DisplayState(duration: controller.sourceDurationSeconds,
                    cuts: edl.cuts.map(\.range),
                    jumpPoints: controller.jumpPoints,
                    playhead: outputPlayhead)
    }

    /// `time` arrives in SOURCE time — the view's own axis — and must be
    /// mapped to TRIMMED time before seeking, since the player plays the
    /// composition built from `keptRanges`, not the source recording.
    ///
    /// A click inside a cut SNAPS to the nearest kept edge rather than
    /// doing nothing. The cut is drawn on the timeline, so it is a visible
    /// thing the user aimed at; swallowing that click with no feedback is
    /// the silent no-op this project keeps finding elsewhere.
    func onScrub(_ time: Double) {
        guard let trimmedTime = TimeRangeMapping.nearestTrimmedTime(
            toSourceTime: time, keptRanges: controller.keptRanges) else { return }
        Task { await controller.seek(toSeconds: trimmedTime) }
    }

    /// `range` arrives in SOURCE time directly from the view — no mapping
    /// needed on the way in, since `edl.cuts` wants exactly that (M4b
    /// Critical finding #1: before this fix, the view's axis was trimmed
    /// time, and a second drag on the same view produced a range that had
    /// already been computed against the wrong clock).
    func onTrim(_ range: TimeRange) {
        applyCut(range)
    }

    /// Appends `range` and registers its inverse as a whole-EDL snapshot,
    /// not an inverse operation (Task 7 ruling): a stack of whole-value
    /// restores is multi-level by construction and cannot drift from the
    /// applied state the way a stack of inverse ops can.
    private func applyCut(_ range: TimeRange) {
        let previous = edl
        undoManager?.registerUndo(withTarget: self) { target in
            target.restore(previous)
        }
        // A drag on the timeline is always a brand-new cut — it has no
        // established identity to preserve, so it mints its own id here.
        edl.cuts.append(Cut(range: range))
        applyAndSave()
    }

    /// Restores a prior whole-EDL snapshot and pushes the CURRENT state back
    /// onto the undo stack as the redo — this is what makes undo/redo
    /// multi-level rather than a single toggle between two states.
    private func restore(_ snapshot: EditDecisionList) {
        let current = edl
        undoManager?.registerUndo(withTarget: self) { $0.restore(current) }
        edl = snapshot
        applyAndSave()
    }

    /// Rebuilds the preview and persists ONLY IF that rebuild succeeded
    /// (Task 7 ordering, corrected by whole-branch review F1).
    ///
    /// The previous spelling was `try? await apply` followed by an
    /// unconditional `try? persist`, under a comment claiming the ordering
    /// protected the document. It did not: ordering alone accomplishes
    /// nothing, only GATING does. `CompositionBuilder` throws
    /// `everythingCut` for a drag across the whole timeline, that EDL was
    /// written anyway, and `DocumentOpener.open` then threw `everythingCut`
    /// forever — D45's own defect ("a `.snitt` could be written and never
    /// reopened") reintroduced by D46's autosave, reachable by one gesture.
    ///
    /// Each save is chained onto the previous one (F2) rather than racing
    /// it, so the last write is the latest state and never the slowest
    /// task's stale one.
    private func applyAndSave() {
        let edl = self.edl
        let events = self.events
        let controller = self.controller
        let previousSave = pendingSaveTask
        outstandingSaves += 1
        pendingSaveTask = Task { @MainActor [weak self] in
            await previousSave?.value
            do {
                try await controller.apply(edl: edl, events: events)
                try controller.persist(edl)
                self?.lastSavedEDL = edl
            } catch {
                self?.editWasRejected(error)
            }
            self?.outstandingSaves -= 1
        }
    }

    /// The compositor refused this edit, so nothing was written — put the
    /// editor back on the state that IS on disk and say so.
    ///
    /// No re-apply is needed: `PreviewController.apply` builds before it
    /// touches the player, so a build that threw has changed nothing and
    /// the preview is still showing `lastSavedEDL`. Reverting `edl` is what
    /// makes the timeline agree with it again.
    ///
    /// The undo entry the refused gesture registered is deliberately left
    /// on the stack: `UndoManager` has no way to pop one, and clearing the
    /// stack would throw away the user's real history to tidy up a failed
    /// edit. It restores the state we have just reverted to, so pressing
    /// ⌘Z once after a refusal is a no-op rather than a surprise.
    private func editWasRejected(_ error: Error) {
        edl = lastSavedEDL
        onEditRejected?(error)
    }

    // MARK: - Testing seam

    /// Awaits the WHOLE chain of enqueued saves, not just the newest task.
    /// Awaiting only the newest is what let F2's older-save-lands-last
    /// inversion slip past every test in this suite.
    func waitForPendingSave() async {
        while let task = pendingSaveTask {
            await task.value
            // Another save may have been enqueued while we were awaiting
            // this one; that new task is now the tail.
            if pendingSaveTask == task { return }
        }
    }
}

/// Embeds `TimelineView` (AppKit) in the SwiftUI shell, driving it from
/// `state` and forwarding its callbacks back into `state`.
private struct TimelineViewRepresentable: NSViewRepresentable {
    @ObservedObject var state: EditorTimelineState
    let playhead: Double

    func makeNSView(context: Context) -> TimelineView {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 480, height: 40))
        view.onScrub = { [weak state] in state?.onScrub($0) }
        view.onTrim = { [weak state] in state?.onTrim($0) }
        return view
    }

    /// Deliberately a one-line delegation to `state.displayState(playhead:)`
    /// — the axis-mapping logic that matters lives there, where it is
    /// testable without AppKit or SwiftUI's runtime; this stays the thin,
    /// untestable seam.
    func updateNSView(_ nsView: TimelineView, context: Context) {
        let display = state.displayState(playhead: playhead)
        nsView.update(duration: display.duration,
                     cuts: display.cuts,
                     jumpPoints: display.jumpPoints,
                     playhead: display.playhead)
    }
}

/// SwiftUI shell around the `AVPlayerLayer` surface: play/pause controls, the
/// timeline, and a jump-point list. §4.7 puts the video surface — and, per
/// Task 6, the timeline's gesture handling — in AppKit while everything
/// around them stays SwiftUI.
private struct EditorContentView: View {
    @ObservedObject fileprivate var state: EditorTimelineState
    @State private var playhead: Double = 0

    private var controller: PreviewController { state.controller }

    var body: some View {
        VStack(spacing: 0) {
            PlayerLayerView(player: controller.player)
                .frame(minWidth: 480, minHeight: 270)
            TimelineViewRepresentable(state: state, playhead: playhead)
                .frame(height: 40)
            HStack(spacing: 12) {
                Button("Play") { controller.play() }
                Button("Pause") { controller.pause() }
            }
            .padding(8)
            if !controller.jumpPoints.isEmpty {
                List(controller.jumpPoints, id: \.timeSeconds) { point in
                    Button(point.label) {
                        Task { await controller.jump(to: point) }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            // Playhead position is appearance only — not asserted by any
            // test (Task 6 dispatch) — so simple polling is enough; a
            // player-driven time observer would add AVFoundation closure
            // plumbing for a value nothing verifies.
            let seconds = controller.player.currentTime().seconds
            playhead = seconds.isFinite ? seconds : 0
        }
    }
}

/// Hosts one editor's preview in its own `NSWindow`.
///
/// Snitt is a regular app (§4.14, D45; see `AppShell`), so its windows can
/// become key the normal way without this controller doing anything about
/// activation policy.
@MainActor
public final class EditorWindowController: NSObject, NSWindowDelegate {
    // The project's logger factory (`SnittLog.logger`), not a hand-rolled
    // `Logger` — see `DocumentOpener`'s identical note. `.compositor`
    // matches `RecordingCoordinator`'s category for the same
    // build-a-composition family of failures (export IS a composition
    // build, per §9).
    private static let log = SnittLog.logger(.compositor, target: "SnittApp")

    private let controller: PreviewController
    private let state: EditorTimelineState
    public let window: NSWindow
    private var isShown = false

    /// The window's `UndoManager` (Task 7) — the same manager Task 1's Edit
    /// menu resolves `undo:`/`redo:` against through the responder chain.
    public var undoManager: UndoManager? { window.undoManager }

    private static var count = 0
    public static var openWindowCount: Int { count }

    /// Retains every open editor for as long as its window is on screen.
    ///
    /// Without this, an editor's ONLY owner is whatever created it. The stop
    /// path that Task 5 adds constructs one and calls `show()` without
    /// holding on to it afterwards — every prior caller of this type was a
    /// test that kept its own `let editor = ...` alive for the whole test, so
    /// this gap never showed up before there was a caller that didn't. A
    /// dropped `EditorWindowController` deallocates: `NSWindow.delegate` is
    /// `weak`, so `windowWillClose` stops firing, and the window itself can
    /// vanish from under a user who is still watching it.
    private static var open: [EditorWindowController] = []

    /// The document this window edits. Standardized on the way in so two
    /// spellings of one path cannot open two windows onto one document —
    /// on macOS `/tmp` is a symlink to `/private/tmp`, so a raw string
    /// comparison would let exactly that through. Once EDL autosave exists
    /// (Task 7), two windows on one bundle means two EDLs over one document
    /// and whichever saves last wins; this identity is what `existing(for:)`
    /// keys reuse on to prevent that.
    public let bundleURL: URL

    /// Looks up an already-open window for `url`, standardizing both sides
    /// of the comparison so `/tmp/x.snitt` and `/private/tmp/x.snitt` — the
    /// same document under two spellings — are recognized as one.
    static func existing(for url: URL) -> EditorWindowController? {
        let wanted = normalizedBundleURL(url)
        return open.first { $0.bundleURL == wanted }
    }

    /// `url.standardizedFileURL.resolvingSymlinksInPath()` alone is not
    /// enough: `resolvingSymlinksInPath()` preserves whatever
    /// has-directory-path hint `url` already carries, and `URL` computes
    /// that hint by checking the filesystem AT THE TIME a `URL` value is
    /// built. Two `URL`s for the identical `/tmp` vs `/private/tmp` bundle
    /// path can therefore resolve to the same string with, and without, a
    /// trailing slash — which `==` treats as different URLs — purely
    /// because of when each one happened to be constructed relative to the
    /// bundle existing on disk. Rebuilding from the plain path with
    /// `URL(fileURLWithPath:)` right before resolving forces both sides to
    /// recompute that hint against the SAME (current, real) filesystem
    /// state, so the trailing slash can no longer differ.
    ///
    /// Not `private`: `DocumentOpener` keys its in-flight registry (F3) on
    /// exactly this identity, and a second normalization written next door
    /// would be a second answer to "is this the same document".
    static func normalizedBundleURL(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path).resolvingSymlinksInPath()
    }

    /// Every currently open editor, for the Window menu's document list
    /// (`AppShell`'s `WindowMenuDelegate`). Not `public` — only `SnittApp`
    /// itself needs to enumerate open editors.
    static var openEditors: [EditorWindowController] { open }

    /// `edl` and `events` are REQUIRED (M4b whole-branch review, Important
    /// finding #3) — a default here existed purely so window-lifecycle tests
    /// that don't care about editing state didn't need touching, which is
    /// test convenience shaping a production signature. A real editor
    /// session must pass the recording's actual EDL and events, or every
    /// trim it draws applies against the wrong starting point and loses the
    /// recording's real markers; making the caller write `.fullRange()` /
    /// `[]` explicitly when that's genuinely what's meant turns "I forgot"
    /// into a build error instead of a silently empty scrub bar.
    public init(controller: PreviewController, title: String, bundleURL: URL,
                edl: EditDecisionList, events: [LoggedEvent]) {
        self.controller = controller
        self.bundleURL = Self.normalizedBundleURL(bundleURL)
        let state = EditorTimelineState(controller: controller, edl: edl, events: events)
        self.state = state
        let hosting = NSHostingView(rootView: EditorContentView(state: state))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = title
        window.contentView = hosting
        // We hold `window` for the controller's lifetime (the `window`
        // property below), so the default release-on-close would fight that
        // ownership; keep the NSWindow alive until we drop our own reference.
        window.isReleasedWhenClosed = false
        // Found by hand (manual "quit and reopen" test after Task 6 made
        // several editor windows open at once): quitting with more than one
        // editor window open segfaulted in `objc_release` inside
        // `-[_NSWindowTransformAnimation dealloc]`, torn down mid-`CATransaction`
        // commit on the main run loop — AppKit's own window-close transform
        // animation racing against several windows closing back-to-back as
        // `-[NSApplication terminate:]` tears them down for quit. `.none`
        // means AppKit never constructs that animation object for this
        // window at all, which removes the crashing class from this app's
        // code path entirely rather than trying to win a race against it.
        // A preview/editor window closing without a zoom/fade transition is
        // not a loss worth keeping this crash for.
        window.animationBehavior = .none
        self.window = window
        super.init()
        window.delegate = self
        // Set only now that `window` exists — this window's `undoManager`
        // (lazily created by AppKit on first access) is what Task 1's Edit
        // menu already resolves `undo:`/`redo:` against through the
        // responder chain.
        state.undoManager = window.undoManager
        // A refused edit has to reach the person who made it (F1). The
        // state cannot present an alert itself — it has no window — so the
        // window controller owns the presentation, exactly as it does for
        // an export failure.
        state.onEditRejected = { [weak self] in self?.presentEditRejection($0) }
    }

    /// Test seam: an alert here runs modal and would hang a test target
    /// that has no one to click it — the same reason `exportForTesting`
    /// exists rather than driving `presentExportPanel`. Set by a test that
    /// needs to observe a refusal; `nil` in production, where the alert is
    /// the whole point.
    var onEditRejectedForTesting: ((Error) -> Void)?

    /// Tells the user that the edit they just made was refused and undone.
    ///
    /// Skipping the write alone would leave a silent no-op: the drag
    /// appears to have done nothing, and the reason (the trim removed the
    /// entire recording) is invisible. `localizedDescription` is NOT shown
    /// or logged here — Snitt's error types are plain enums, so it renders
    /// as an opaque `CompositionError` string that tells a user nothing.
    private func presentEditRejection(_ error: Error) {
        let ns = error as NSError
        Self.log.error("Refused an edit the compositor rejected: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
        if let observe = onEditRejectedForTesting {
            observe(error)
            return
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Snitt could not make that edit."
        alert.informativeText = "The edit was undone and nothing was saved. "
            + "A trim that removes the whole recording is the usual cause."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Brings the window to the front.
    public func show() {
        if !isShown {
            isShown = true
            Self.count += 1
            Self.open.append(self)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Stops playback and closes the window. Safe to call more than once,
    /// and safe even if the window was already closed via its own close
    /// button (`windowWillClose` runs the same teardown).
    public func close() {
        guard isShown else { return }
        teardown()
        window.close()
    }

    public func windowWillClose(_ notification: Notification) {
        teardown()
    }

    /// The one place that leaves the open count and pauses playback — run
    /// exactly once per window, however the close was triggered.
    private func teardown() {
        guard isShown else { return }
        isShown = false
        // A closed window whose player keeps playing leaves audio coming
        // from a window the user can no longer see.
        controller.pause()
        Self.count -= 1
        Self.open.removeAll { $0 === self }
    }

    // MARK: - Export (Task 8)

    /// File ▸ Export…, wired via `AppDelegate.exportDocument(_:)`.
    ///
    /// Opens an `NSSavePanel` and, on a chosen destination, runs the SAME
    /// export path `AutomationHost.export` already uses (`MovieExporter`
    /// over `CompositionBuilder`) against `state.edl` — the exact EDL the
    /// preview is currently showing, not a re-read of `edit.json` from
    /// disk. Task 7's autosave means those normally agree, but reading the
    /// in-memory value is what keeps them agreeing even for the instant
    /// between a trim and its `applyAndSave` write landing, and it is what
    /// §9 ("preview and export share one builder") actually asks for:
    /// this is the EDL the on-screen preview was built from, not a second,
    /// separately-sourced one that merely usually matches it.
    public func presentExportPanel() {
        let panel = NSSavePanel()
        if let mp4 = UTType(filenameExtension: "mp4") {
            panel.allowedContentTypes = [mp4]
        }
        panel.nameFieldStringValue = bundleURL.deletingPathExtension().lastPathComponent
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            Task { @MainActor in
                do {
                    try await self.performExport(to: destination, pasteboard: .general)
                    self.presentExportSuccess()
                } catch {
                    self.presentExportFailure(error)
                }
            }
        }
    }

    /// The actual export: build via `MovieExporter.export` (which builds
    /// through `CompositionBuilder`, never a second one of its own — §9),
    /// then re-copy the result to `pasteboard`, SUPERSEDING
    /// `RecordingCoordinator`'s stop-time copy of the raw, untrimmed
    /// `capture.mov`. Without this, that stale copy is the last thing that
    /// ever touched the clipboard for this recording, and a user who
    /// trimmed and pasted ships the version they just cut content out of —
    /// silently, with no error anywhere (Task 8's second defect).
    ///
    /// Rebuilds `SnittBundle` from `bundleURL` rather than keeping a
    /// `SnittBundle` of its own: `PreviewController`'s is `private` (R1 —
    /// the write belongs with the owner), and `bundleURL` is already this
    /// type's own normalized identity for exactly this document.
    private func performExport(to destination: URL, pasteboard: NSPasteboard) async throws {
        let bundle = try SnittBundle(opening: bundleURL)
        _ = try await MovieExporter.export(bundle: bundle, edl: state.edl, scale: 1.0, to: destination)
        if !ClipboardDestination.copy(fileURL: destination, to: pasteboard) {
            // The export itself succeeded — the file the user asked for
            // exists at `destination` — so this is not surfaced as an
            // export failure. It IS logged: a copy that silently didn't
            // happen is exactly the kind of clipboard mismatch this task
            // exists to eliminate, just moved one step later.
            Self.log.error("Export succeeded but the clipboard copy did not.")
        }
    }

    private func presentExportSuccess() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Exported and copied to the clipboard."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Same redaction discipline as `DocumentOpener`'s catch — domain, code,
    /// never `String(describing:)` on the error and never a path — with one
    /// deliberate difference: `localizedDescription` is `.private` here.
    ///
    /// `RecordingCoordinator`'s `.public` on the same field is justified by
    /// "localizedDescription names only fixed sidecar filenames", which is
    /// true on the open paths (`manifest.json`, `edit.json`, `events.jsonl`,
    /// `capture.mov`) and FALSE here (whole-branch review F6): the export
    /// destination is chosen by the user in an `NSSavePanel` and can be
    /// anywhere, so a Cocoa write failure names a folder of theirs in a
    /// field `snitt diagnostics export` collects verbatim.
    /// `UpdaterController` already marks this field `.private` for the same
    /// reason; this matches it rather than adding a third convention.
    private func presentExportFailure(_ error: Error) {
        let ns = error as NSError
        Self.log.error("Export failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .private)")
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Snitt could not export this recording."
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Testing seam

    /// Drives an export exactly as `presentExportPanel()`'s save-panel
    /// callback would, without a real `NSSavePanel` or the success/failure
    /// `NSAlert` (both require a live window server this test target
    /// cannot assume). `pasteboard` defaults to `.general` for parity with
    /// the real path but is overridable so a test can assert against a
    /// throwaway pasteboard instead of the machine's real clipboard.
    func exportForTesting(to url: URL, pasteboard: NSPasteboard = .general) async throws {
        try await performExport(to: url, pasteboard: pasteboard)
    }

    /// Closes every editor `EditorWindowController` currently thinks is
    /// open, exactly as if each had gone through `close()`.
    ///
    /// M4a review finding #3: a test that opens an editor through
    /// `RecordingCoordinator.stopForTesting()` — which constructs the
    /// `EditorWindowController` internally and never hands it back — has no
    /// other way to tear it down, so it leaked a real window (and a bumped
    /// `openWindowCount`) for the rest of the run. `close()` itself is
    /// idempotent and per-instance; this just calls it for every instance
    /// still in `open`, using a copy of the array since `close()` mutates
    /// `open` as it runs.
    static func closeAllForTesting() {
        for editor in open {
            editor.close()
        }
    }

    /// Drives a trim exactly as the timeline view's gesture would, without
    /// a live `NSView` or SwiftUI runtime (Task 7).
    func applyTrimForTesting(_ range: TimeRange) {
        state.onTrim(range)
    }

    /// The in-memory EDL. Deliberately the ADJACENT property to the one
    /// `EditorPersistenceTests` cares about — see that suite's doc comments
    /// for why asserting only this would pass against the bug Task 7 fixes.
    func currentEDLForTesting() -> EditDecisionList {
        state.edl
    }

    /// Awaits the actual in-flight apply-then-persist chain, not a fixed
    /// sleep — a test that slept would be a flake this project has already
    /// paid for once.
    func waitForPendingSaveForTesting() async {
        await state.waitForPendingSave()
    }

    // MARK: - Termination (F9)

    /// Whether any open editor still has an autosave in flight.
    ///
    /// Autosave runs an unstructured `Task`, so ⌘Q (or the status item's
    /// Quit) pressed straight after a trim used to terminate the process
    /// before `apply` + `persist` finished, silently losing the edit. With
    /// F1's gate in place this is the last remaining path by which an edit
    /// disappears.
    static var hasPendingSaves: Bool {
        open.contains { $0.state.outstandingSaves > 0 }
    }

    /// Drains every open editor's autosave chain. Called from
    /// `applicationShouldTerminate` before the process exits.
    static func flushPendingSaves() async {
        for editor in open {
            await editor.state.waitForPendingSave()
        }
    }
}

/// Cross-suite serialization for tests that read `EditorWindowController`'s
/// process-global `openWindowCount` around a `before`/`after` snapshot.
///
/// `@Suite(.serialized)` (used by `DocumentOpenerTests`,
/// `EditorWindowControllerTests`, and `EditorPersistenceTests`) only
/// serializes tests WITHIN one suite — swift-testing runs different suites
/// concurrently by default. All three of those suites open real, real
/// front-ordered windows and read this same static counter, so without this
/// gate a window opened by one suite's test can land in the middle of
/// another suite's `before`/`after` window, changing the count out from
/// under an assertion that has no way to see it happening. Discovered by
/// running the full suite repeatedly after adding `EditorPersistenceTests`
/// (Task 7): two of four consecutive runs failed with
/// `EditorWindowControllerTests`'s open-count assertions off by exactly the
/// window `EditorPersistenceTests` had open at the time — not a segfault,
/// but the same class of hazard the M5c test-infrastructure note warns
/// about, one level up (a shared counter instead of a shared `NSWindow`).
///
/// `@MainActor`, not a separate `actor`: every caller here already runs on
/// `@MainActor` (these tests construct real `NSWindow`s, which requires
/// it), and `body` closures capture MainActor-isolated, non-`Sendable`
/// state (`EditorWindowController`, `PreviewController`). Routing through
/// a distinct actor would require SENDING that closure across an isolation
/// boundary — exactly the `Sendable`-crossing error `-strict-concurrency
/// =complete` exists to catch — for no benefit, since there is only ever
/// one MainActor to contend for anyway.
@MainActor
enum EditorWindowTestGate {
    private static var locked = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    private static func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private static func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Runs `body` with the gate held for its ENTIRE duration — the whole
    /// snapshot-mutate-assert critical section a test cares about, not just
    /// the moment a window is created.
    static func run<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}
