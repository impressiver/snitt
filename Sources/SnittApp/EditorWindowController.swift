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
/// Not `private`: `@testable import SnittApp` needs to drive `onSelect` /
/// `cutSelection` and read `displayState(playhead:)` directly to verify the
/// M4b Critical finding — that a SECOND trim in one session removes a
/// distinct region — without a live `NSWindow` or SwiftUI's runtime.
@MainActor
final class EditorTimelineState: ObservableObject {
    let controller: PreviewController
    /// Every logged event — markers among them — in SOURCE time. Mutable as
    /// of M5f Task 6 (D56/D50): a marker drag or edit mutates this array and
    /// persists it to `events.json` via `applyAndSaveEvents()`, exactly as
    /// `edl` mutates and persists to `edit.json`. `private(set)`: every
    /// mutation goes through `moveMarker`/`updateMarker` below, which are
    /// what register undo and enqueue the save — a caller reaching in and
    /// assigning this directly would skip both.
    @Published private(set) var events: [LoggedEvent]
    @Published var edl: EditDecisionList

    /// The current selection (SOURCE time), or `nil`. D56 (M5f Task 4): UI
    /// state only — never written into `edl`, never persisted, and this is
    /// the ONLY place it lives; `EditDecisionList` has no field for it.
    /// `@Published` so `EditorContentView`'s Cut button can enable/disable
    /// on it and `TimelineViewRepresentable` can feed it back down to the
    /// view for drawing.
    @Published var selection: Selection?

    /// Which folds are currently expanded, by `Cut.id` (D56, M5f Task 5).
    ///
    /// UI state ONLY, exactly like `selection` above: nothing here is ever
    /// written into `edl`, never persisted, and `EditDecisionList`/`Cut`
    /// have no field for it at all. That is the whole point — the dispatch's
    /// first trap. Expanding a fold must not change `Timebase.outputDuration`
    /// or where the playhead maps, and the only way to GUARANTEE that rather
    /// than merely intend it is for the expansion set to live somewhere
    /// `edl`-mutating code (`applyCut`, `restore`, `removeCut` below) never
    /// touches — `toggleExpansion(of:)` is the one place this changes, and it
    /// does not call `applyAndSave()`, so no compositor rebuild, no
    /// `persist`, and no undo registration ever happens for it. Compare
    /// `removeCut(id:)`, which DOES mutate `edl` and goes through exactly
    /// that machinery, because removing a cut is a real edit and expanding
    /// one is only ever a way of looking at it.
    @Published var expandedCutIDs: Set<UUID> = []

    /// The window's `UndoManager` (Task 7), set once the window exists —
    /// this type is constructed before the `NSWindow` that owns it. Task
    /// 1's Edit menu already wires `undo:`/`redo:` to the responder chain;
    /// registering against the window's own manager, rather than a private
    /// one, is what makes those menu items resolve to something instead of
    /// nothing.
    weak var undoManager: UndoManager?
    /// The timeline view, so the on-screen zoom controls can reach it.
    ///
    /// Zoom has existed since M5f Task 8 — `zoomIn()`, `zoomOut()`, scroll and
    /// pinch — but nothing on screen called any of it, so the only ways in were
    /// a trackpad gesture and a keyboard shortcut on a view that has to be
    /// first responder. A feature reachable only by guessing is not reachable.
    weak var timelineView: TimelineView?

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
    /// Whether any edit has been applied and saved since this window opened.
    ///
    /// Drives the Finder icon's refresh on close. `EditDecisionList` is not
    /// `Equatable`, and making it so would mean conforming `TrackState` too —
    /// a shared type changed for a decoration. A flag set where edits are
    /// already being saved answers the same question without that.
    var editsChangedTheRecording = false

    private var lastSavedEDL: EditDecisionList

    /// The events-side twin of `lastSavedEDL` (Task 6): the last `events`
    /// value that both applied and persisted, for `eventEditWasRejected(_:)`
    /// to revert to.
    private var lastSavedEvents: [LoggedEvent]

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
        self.lastSavedEvents = events
        loadWaveforms()
    }

    /// Peak amplitudes per audio track, empty until the read finishes.
    ///
    /// Empty is a legitimate state the timeline draws as a plain band, not an
    /// error: reading every audio sample of a long recording takes real time,
    /// and blocking the editor's first paint on it would be a worse trade than
    /// a waveform that arrives a moment later.
    @Published var waveforms: [WaveformSamples] = []
    /// Whether waveform sampling has FINISHED, regardless of what it found.
    ///
    /// `waveforms.isEmpty` alone cannot tell "this recording has no audio" from
    /// "the audio has not been decoded yet", and those need opposite answers
    /// from `autoDeepTrim`.
    @Published var waveformsLoaded = false

    /// Thumbnails for the video track, empty until decoding finishes — drawn
    /// as a plain band until then, for the same reason as `waveforms`.
    @Published var filmstrip: FilmstripFrames?

    /// Sampled ONCE per document, against the source recording. Cuts and zoom
    /// change which sample a pixel column reads (`TimelineSampleIndex`), never
    /// the samples themselves, so no edit re-triggers this.
    private func loadWaveforms() {
        let url = controller.captureURL
        Task { [weak self] in
            let samples = try? await WaveformSampler.sample(movieAt: url)
            await MainActor.run {
                self?.waveforms = samples ?? []
                // Set even when the result is empty: a recording with no audio
                // track samples to nothing, and without this flag that is
                // indistinguishable from "still decoding" forever.
                self?.waveformsLoaded = samples != nil
            }
        }
        Task { [weak self] in
            // Separate task from the waveform's: a long audio read must not
            // delay the filmstrip, and vice versa. Whichever finishes first
            // paints first.
            let frames = try? await FilmstripSampler.sample(movieAt: url)
            await MainActor.run { self?.filmstrip = frames }
        }
    }

    /// Everything `TimelineView` needs. `duration`/`cuts`/`selection` stay on
    /// the SOURCE clock because that is the clock they ARE: `edl.cuts` and a
    /// `Selection` destined to become one are source-time ranges, and
    /// `duration` is `capture.mov`'s own length — the INPUT the view builds
    /// its `Timebase` (and therefore its one output-axis `TimelineGeometry`)
    /// from, not an axis it interprets anything against.
    ///
    /// This comment used to say the view's own interaction "must keep
    /// computing against the recording's FULL, unchanging length regardless
    /// of what has already been cut", citing M4b Critical finding #1. The
    /// M5f whole-branch review measured that arrangement and found it
    /// REPRODUCED the finding it cited: a fixed axis makes the same pixels
    /// mean the same source span forever, so a second drag over them cuts
    /// nothing. Interaction is interpreted on the axis being drawn — see
    /// `TimelineView.time(for:)`.
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
        /// WITH identity (M5f Task 5) — `edl.cuts` itself, not
        /// `.map(\.range)`. `TimelineView.foldHit(atX:)` reports a click back
        /// by `Cut.id` (to `onToggleExpansion`/`onRemoveCut`), so the id has
        /// to survive the trip down to the view; a bare `TimeRange` here
        /// would strip exactly the identity the fold UI needs.
        let cuts: [Cut]
        /// The marker TRACK's points — includes markers inside cuts, drawn at
        /// the fold. Not `controller.jumpPoints`, which drops them.
        let markerPoints: [JumpPoint]
        let playhead: Double
        let selection: Selection?
        /// See `expandedCutIDs`'s own doc comment.
        let expandedCutIDs: Set<UUID>
        /// Which audio sources exist and whether each is muted. The timeline
        /// draws one band per source, so muting has a visible effect — until
        /// now `TrackState.muted` changed the export and nothing on screen.
        let trackStates: [TrackState]
        /// Source-time peaks per track; empty until sampling finishes.
        let waveforms: [WaveformSamples]
        /// Source-time thumbnails; nil until decoding finishes.
        let filmstrip: FilmstripFrames?
    }

    func displayState(playhead outputPlayhead: Double) -> DisplayState {
        DisplayState(duration: controller.sourceDurationSeconds,
                    cuts: edl.cuts,
                    markerPoints: controller.markerTrackPoints,
                    playhead: outputPlayhead,
                    selection: selection,
                    expandedCutIDs: expandedCutIDs,
                    trackStates: edl.trackStates,
                    waveforms: waveforms,
                    filmstrip: filmstrip)
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

    /// `selection` arrives from the view already resolved (SOURCE time): a
    /// real drag becomes `Selection(range:)`, a plain click — or a drag too
    /// short to count — becomes `nil`. D56 (M5f Task 4): this only ever
    /// REPLACES `self.selection`. It never touches `edl` — a drag selects,
    /// it does not cut. `cutSelection()`, below, is the one path from a
    /// selection to an actual `Cut`.
    ///
    /// Before this task, this method was `onTrim(_ range: TimeRange)` and
    /// called `applyCut(range)` directly — a completed drag became a cut
    /// the instant the mouse came up, with no decision in between. That is
    /// the defect D56 names.
    func onSelect(_ selection: Selection?) {
        self.selection = selection
    }

    /// Cuts the current selection, if any — the one place a `Selection`
    /// (UI state, never persisted) turns into a `Cut` (persisted to
    /// `edit.json`), via the same append-and-save `applyCut` a drag used to
    /// call directly before D56 separated the two. Clears the selection
    /// afterwards: once it has become an edit, there is nothing left
    /// selected. A no-op with no selection, rather than force-unwrapping —
    /// pressing Cut with nothing selected is a plausible, harmless mistake,
    /// not a programmer error.
    func cutSelection() {
        guard let selection else { return }
        applyCut(selection.range)
        self.selection = nil
    }

    /// A fold was clicked (`TimelineView.onToggleExpansion`, D56 M5f Task 5):
    /// flips whether `id` is expanded. Deliberately the ONLY thing this
    /// method does — no `applyCut`/`restore`-style undo registration, no
    /// `applyAndSave()`. See `expandedCutIDs`'s doc comment for why that
    /// absence is the whole guarantee: a "plausible wrong implementation"
    /// the dispatch names is one that treats expanding as a temporary
    /// un-cut (restoring the segment, rebuilding the composition, then
    /// re-cutting it on collapse) — that WOULD change `outputDuration` and
    /// briefly make playback stop skipping the span, exactly the leak Task
    /// 5's first trap exists to catch.
    func toggleExpansion(of id: UUID) {
        if expandedCutIDs.contains(id) {
            expandedCutIDs.remove(id)
        } else {
            expandedCutIDs.insert(id)
        }
    }

    /// Right-click ▸ Remove Cut (D56, M5f Task 5): restores the segment by
    /// deleting exactly the `Cut` named by `id` from `edl.cuts` — output
    /// duration grows by that cut's own length, and nothing else in the EDL
    /// changes. Mirrors `applyCut`'s undo/save shape exactly (a whole-EDL
    /// snapshot registered before the mutation, then `applyAndSave()`),
    /// because removal is a real edit with the same undo/persist
    /// obligations as a cut — it is NOT the same operation as
    /// `toggleExpansion(of:)` above just running backwards.
    ///
    /// A no-op if `id` doesn't name a current cut — a stale fold (already
    /// removed by an earlier right-click, or by an undo that has since
    /// dropped it) offering "Remove Cut" a second time is a plausible,
    /// harmless double-click, not a programmer error, matching
    /// `cutSelection()`'s own no-op-over-force-unwrap stance above.
    func removeCut(id: UUID) {
        guard edl.cuts.contains(where: { $0.id == id }) else { return }
        var updated = edl
        updated.cuts.removeAll { $0.id == id }
        let previous = edl
        undoManager?.registerUndo(withTarget: self) { target in
            target.restore(previous)
        }
        edl = updated
        // The removed cut can no longer be expanded — nothing left to fold.
        expandedCutIDs.remove(id)
        applyAndSave()
    }

    // MARK: - Markers (D50/D56, M5f Task 6)

    /// A marker was dragged to a new position on the timeline.
    ///
    /// `outputTime` arrives in OUTPUT time — the timeline's own drawing
    /// axis (Task 3) — and MUST be converted back to SOURCE time before
    /// it is stored: `events.json` holds source time, the same clock
    /// `edl.cuts` uses, and storing the output value directly would be the
    /// M4b defect wearing a different hat — a marker that moves on screen
    /// and lands at the wrong instant in the file, silently, the moment
    /// anything has been cut. `Timebase.sourceTime(forOutput:)` (Task 3) is
    /// the one place that conversion lives; this is not a second one.
    ///
    /// `Timebase.sourceTime(forOutput:)` can never resolve to an instant
    /// INSIDE a cut — the output timeline has no cuts in it by construction
    /// (see that method's own doc comment) — so a drag can never place a
    /// marker into a cut merely by landing on a pixel; every reachable
    /// output position already names a kept source instant. The opposite
    /// case — a marker that already sits inside a cut before any drag — has
    /// no output position at all, so `TimelineView` never draws it in the
    /// marker track and this method is never reached for it: there is
    /// nothing on screen for a person to grab.
    ///
    /// A no-op if `id` doesn't name a current event (already moved by a
    /// concurrent edit, or the marker was removed) or if `outputTime`
    /// resolves to nothing (everything is currently cut, so there is no
    /// output timeline to land on) — both plausible, harmless races, not
    /// programmer errors, matching `removeCut(id:)`'s own no-op stance.
    func moveMarker(id: UUID, toOutput outputTime: Double) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        let timebase = Timebase(sourceDuration: controller.sourceDurationSeconds, edl: edl)
        guard let sourceTime = timebase.sourceTime(forOutput: OutputTime(outputTime))?.seconds else { return }
        let previous = events
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreEvents(previous)
        }
        events[index].timeSeconds = sourceTime
        applyAndSaveEvents()
    }

    /// A marker's label and transcript (D50) were edited. Both are written
    /// together — the one UI that calls this always presents both fields at
    /// once, so there is no partial-edit case to support, and supporting
    /// one independently would risk a caller silently clobbering the other
    /// with a stale value.
    ///
    /// A no-op if `id` doesn't name a current event, matching `moveMarker`
    /// and `removeCut(id:)` above.
    func updateMarker(id: UUID, label: String?, transcript: String?) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        let previous = events
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreEvents(previous)
        }
        events[index].label = label
        events[index].transcript = transcript
        applyAndSaveEvents()
    }

    // MARK: - Automatic trimming (D57)

    /// What the last automatic trim did, for the caption beside the button.
    @Published var lastTrimOutcome: DeepTrimOutcome?

    /// Why an automatic trim found nothing, when it found nothing.
    ///
    /// A button that silently does nothing is indistinguishable from a broken
    /// one, and the two reasons this finds nothing are completely different
    /// problems: "there was no dead air" is a fine outcome, "the recording has
    /// not finished loading its waveform yet" is a wait.
    enum DeepTrimOutcome: Equatable {
        case cut(spans: Int, seconds: Double)
        case nothingToCut
        case notReady
    }

    /// Cuts every span of the recording where nothing happened (D57).
    ///
    /// Runs over the signals the editor has ALREADY decoded for the timeline —
    /// the waveforms, the filmstrip, the event log and the transcript — so this
    /// costs a pass over arrays in memory rather than a second decode of the
    /// movie. D57 called a dedicated decode "a real architectural fork"; this
    /// takes the other branch, and the cost is resolution: the filmstrip is
    /// capped at a few hundred frames, so on a long recording the picture is
    /// sampled every few seconds and only generously-sized dead spans are
    /// detectable. That is the right trade for the feature's actual job, which
    /// is removing the minute someone spent reading documentation, not the
    /// half-second between two clicks.
    ///
    /// The result is ordinary cuts on the shared undo stack — reversible folds
    /// (D56 Tier 1), individually removable — rather than a bulk edit that has
    /// to be accepted whole.
    @discardableResult
    func autoDeepTrim(preset: DeepTrimPreset) -> DeepTrimOutcome {
        func finish(_ outcome: DeepTrimOutcome) -> DeepTrimOutcome {
            lastTrimOutcome = outcome
            return outcome
        }
        guard waveformsLoaded, let filmstrip, !filmstrip.frames.isEmpty else {
            return finish(.notReady)
        }
        // A recording with no audio track is SILENT, not unmeasured — and
        // those are the recordings most likely to have dead air, since a
        // silent screencast is usually an agent's.
        let audio: AudioEvidence = waveforms.isEmpty ? .silentByConstruction
                                                     : .sampled(waveforms)
        let kept = KeptRanges.compute(duration: controller.sourceDurationSeconds,
                                      cuts: edl.cuts.map(\.range))
        let found = AutoDeepTrim.deadSpans(
            duration: controller.sourceDurationSeconds,
            audio: audio,
            frames: FrameActivity.from(filmstrip),
            transcript: transcript,
            events: events,
            criteria: .preset(preset))
        // Anything already removed is not proposed again: re-running this after
        // a trim would otherwise stack a second fold onto material that is
        // already gone, which reads as the button misbehaving.
        let fresh = found.filter { span in
            kept.contains { $0.start < span.end && span.start < $0.end }
        }
        guard !fresh.isEmpty else { return finish(.nothingToCut) }

        let previous = edl
        undoManager?.registerUndo(withTarget: self) { target in
            target.restore(previous)
        }
        edl.cuts.append(contentsOf: fresh.map { Cut(range: $0) })
        applyAndSave()
        return finish(.cut(spans: fresh.count,
                           seconds: fresh.reduce(0) { $0 + ($1.end - $1.start) }))
    }

    // MARK: - Chapter index (the marker pane)

    /// The markers as a chapter list, in the order they occur.
    ///
    /// Derived rather than stored: `events` is the single source of truth for
    /// markers, and a parallel list would be one more thing to keep in step
    /// with cuts, undo, and the timeline lane — which all already read
    /// `events`.
    ///
    /// Built on `MarkerTrackPoints` — the SAME projection the timeline lane
    /// draws — rather than re-deriving the source-to-output arithmetic here.
    /// `MarkerJumpPoints.swift` warns in its own comment that "a chapter list
    /// and a scrub bar that disagree about the same recording are worse than
    /// either alone"; two implementations of one projection is how they come
    /// to disagree. This one shares the lane's, so the panel and the lane
    /// cannot drift.
    ///
    /// `MarkerTrackPoints` rather than `MarkerJumpPoints` because the latter
    /// DROPS markers inside cuts. That is right for a bare seek list and wrong
    /// here: a marker vanishing from the index because a nearby cut swallowed
    /// it looks like data loss, when the marker is still in `events.json` and
    /// moving the cut brings it back. Kept, folded to the cut's edge, and
    /// labelled as such.
    var chapters: [MarkerChapter] {
        // Whether a label is the user's or the fallback — `JumpPoint.label`
        // has already applied "Marker" by the time it arrives, so the
        // distinction has to come from the event itself.
        var custom: [UUID: String] = [:]
        for event in events where event.kind == .marker {
            if let label = event.label, !label.isEmpty { custom[event.id] = label }
        }
        return MarkerTrackPoints.compute(events: events, keptRanges: controller.keptRanges)
            .enumerated()
            .map { index, point in
                MarkerChapter(
                    id: point.id,
                    outputTime: point.timeSeconds,
                    isInsideCut: point.isInsideCut,
                    label: custom[point.id] ?? "Marker \(index + 1)",
                    hasCustomLabel: custom[point.id] != nil,
                    transcript: point.transcript)
            }
    }

    /// Which chapter the playhead is inside.
    ///
    /// A chapter runs until the NEXT one starts — that is what makes this an
    /// index rather than a list of instants. Highlighting only while the
    /// playhead sits exactly on a marker would mean nothing is ever
    /// highlighted, since a marker has no duration.
    func currentChapterID(atOutputSeconds outputSeconds: Double) -> UUID? {
        var current: UUID?
        for chapter in chapters {
            // A small tolerance so seeking TO a chapter highlights it rather
            // than landing a hair before its own start.
            if chapter.outputTime <= outputSeconds + 0.01 { current = chapter.id } else { break }
        }
        return current
    }

    /// Drops a marker at the playhead.
    ///
    /// Until now markers could only be created while recording, which means a
    /// recording made by an agent — or by anyone who did not think to press
    /// the key at the right moment — could never be chaptered at all.
    func addMarker(atOutput outputTime: Double) {
        let timebase = Timebase(sourceDuration: controller.sourceDurationSeconds, edl: edl)
        guard let sourceTime = timebase.sourceTime(forOutput: OutputTime(outputTime))?.seconds
        else { return }
        let previous = events
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreEvents(previous)
        }
        events.append(LoggedEvent(timeSeconds: sourceTime, kind: .marker))
        // Kept in time order for the same reason `Recorder` sorts before
        // writing: every consumer reads this array as a timeline.
        events.sort { $0.timeSeconds < $1.timeSeconds }
        applyAndSaveEvents()
    }

    /// Removes a marker. Undoable on the same stack as every other edit.
    func deleteMarker(id: UUID) {
        guard let index = events.firstIndex(where: { $0.id == id }),
              events[index].kind == .marker else { return }
        let previous = events
        undoManager?.registerUndo(withTarget: self) { target in
            target.restoreEvents(previous)
        }
        events.remove(at: index)
        applyAndSaveEvents()
    }

    /// Renames a marker, keeping its transcript.
    ///
    /// Goes through `updateMarker` rather than writing `label` directly,
    /// because that method's whole contract is that both fields are written
    /// together — a rename that passed `transcript: nil` would silently
    /// destroy narration text the sheet had set.
    func renameMarker(id: UUID, to label: String) {
        guard let event = events.first(where: { $0.id == id }) else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        updateMarker(id: id, label: trimmed.isEmpty ? nil : trimmed,
                     transcript: event.transcript)
    }

    /// Seeks the preview to a chapter. Through `onScrub` for the same reason
    /// `seek(toWord:)` is: it is the one path that keeps the timeline playhead
    /// and the panes agreeing about where playback is.
    func seek(toOutput seconds: Double) { onScrub(seconds) }

    /// The events-side twin of `restore(_:)`: pushes the CURRENT `events`
    /// back onto the undo stack as the redo before installing `snapshot`, so
    /// marker undo/redo is multi-level exactly like cut undo/redo.
    private func restoreEvents(_ snapshot: [LoggedEvent]) {
        let current = events
        undoManager?.registerUndo(withTarget: self) { $0.restoreEvents(current) }
        events = snapshot
        applyAndSaveEvents()
    }

    /// The marker-edit sibling of `applyAndSave()`: persists `events.json`
    /// only, WITHOUT rebuilding the composition. A marker's own position,
    /// label or transcript changes nothing `CompositionBuilder` builds —
    /// only `edl.cuts` does — so this calls `controller.refreshJumpPoints`
    /// directly instead of the full `apply(edl:events:)` rebuild `cuts` need.
    ///
    /// Chained onto the SAME `pendingSaveTask` `applyAndSave()` uses, not a
    /// second, parallel chain: F2's "last write is the latest state" and
    /// F9's "⌘Q waits for every outstanding save" both need to hold for a
    /// marker edit exactly as they do for a cut, and two independent chains
    /// could let a cut and a marker edit race each other onto disk.
    private func applyAndSaveEvents() {
        let events = self.events
        let controller = self.controller
        let previousSave = pendingSaveTask
        outstandingSaves += 1
        pendingSaveTask = Task { @MainActor [weak self] in
            await previousSave?.value
            do {
                try controller.persistEvents(events)
                controller.refreshJumpPoints(events: events)
                self?.lastSavedEvents = events
            } catch {
                self?.eventEditWasRejected(error)
            }
            self?.outstandingSaves -= 1
        }
    }

    /// The events-side twin of `editWasRejected(_:)`: reverts to the last
    /// events value that IS on disk and reuses the same alert path — a
    /// marker write failing (disk full, permissions) deserves the same
    /// visible refusal a rejected cut gets, not a silently reverted marker.
    private func eventEditWasRejected(_ error: Error) {
        events = lastSavedEvents
        onEditRejected?(error)
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
        // Cutting a selection is always a brand-new cut — it has no
        // established identity to preserve, so it mints its own id here.
        edl.cuts.append(Cut(range: range))
        applyAndSave()
    }

    /// Applies a crop drawn over the preview.
    ///
    /// `sub` is expressed in the coordinates of the frame CURRENTLY on screen,
    /// which is already cropped if a crop exists — so it composes rather than
    /// replaces (`CropRect.composing`). Undo goes through the same whole-EDL
    /// snapshot `cutSelection` uses, so a crop is as undoable as a cut and the
    /// two interleave on one stack.
    func applyCrop(_ sub: CropRect) {
        let current = edl
        undoManager?.registerUndo(withTarget: self) { $0.restore(current) }
        edl.crop = (edl.crop ?? .full).composing(sub)
        applyAndSave()
    }

    // MARK: - Transcript (D62)

    enum TranscriptionStatus: Equatable {
        /// No transcript and no way to make one (no mic track, or unsupported).
        case none
        /// Available but the user has not been asked for the Speech grant yet —
        /// §4.10: ask at first USE, so the pane shows a button, not a dialog.
        case needsPermission
        case transcribing
        case ready
        case failed(String)
    }

    @Published var transcript: Transcript?
    @Published var transcriptionStatus: TranscriptionStatus = .none

    /// Words currently removed by the EDL, for striking through.
    ///
    /// Derived, never stored on the word: the EDL is the single source of what
    /// is cut, so undoing a cut un-strikes the words with no bookkeeping.
    var cutWordIDs: Set<UUID> {
        guard let transcript else { return [] }
        return TranscriptEditing.cutWordIDs(in: transcript, cuts: edl.cuts)
    }

    /// Loads transcript.json if the bundle has one. Separated from
    /// `beginTranscriptionIfNeeded` so tests can exercise the load/edit path
    /// without the TCC-gated recognizer anywhere near them.
    func loadTranscript() {
        guard let existing = try? Transcript.read(from: controller.snittBundle) else { return }
        transcript = existing
        lastSavedTranscript = existing
        transcriptionStatus = .ready
    }

    /// Kicks off transcription when there is no transcript yet and the
    /// recognizer is usable. Called by the window controller after the editor
    /// opens — deliberately NOT from init, so the test host never constructs a
    /// recognizer as a side effect of making a state.
    func beginTranscriptionIfNeeded() {
        guard transcript == nil, transcriptionStatus == .none else { return }
        switch Transcriber.availability() {
        case .unsupported, .denied: transcriptionStatus = .none
        case .notYetRequested: transcriptionStatus = .needsPermission
        case .available: startTranscription()
        }
    }

    /// The §4.10 rung: the user clicked "Transcribe", so NOW the dialog has a
    /// visible cause.
    func requestTranscriptionPermission() {
        Task { [weak self] in
            let granted = await Transcriber.requestAuthorization()
            await MainActor.run {
                guard let self else { return }
                if granted { self.startTranscription() } else { self.transcriptionStatus = .none }
            }
        }
    }

    private func startTranscription() {
        transcriptionStatus = .transcribing
        let bundle = controller.snittBundle
        Task { [weak self] in
            do {
                guard let result = try await Transcriber.transcribe(bundle: bundle) else {
                    // No mic track — a normal recording, not a failure.
                    await MainActor.run { self?.transcriptionStatus = .none }
                    return
                }
                try result.write(to: bundle)
                await MainActor.run {
                    self?.transcript = result
                    self?.lastSavedTranscript = result
                    self?.transcriptionStatus = .ready
                }
            } catch {
                await MainActor.run {
                    self?.transcriptionStatus = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// The word being spoken at `outputSeconds`, for playback highlighting.
    ///
    /// Derived on demand rather than stored: the playhead moves ten times a
    /// second and the answer is a pure function of it, so caching would add a
    /// second source of truth for something already cheap to compute.
    func currentWordID(atOutputSeconds outputSeconds: Double) -> UUID? {
        guard let transcript else { return nil }
        return TranscriptPlayhead.currentWordID(outputSeconds: outputSeconds,
                                                words: transcript.words,
                                                keptRanges: controller.keptRanges)
    }

    /// Whether the preview is actually playing, so the transcript follows only
    /// then — auto-scrolling while someone is reading and selecting would drag
    /// the text out from under them.
    var isPlaying: Bool { controller.player.rate != 0 }

    /// Corrects one recognized word's text (D62 second slice).
    ///
    /// Text only — the timing is untouched, because the word WAS said at that
    /// instant; only the spelling was wrong. Changing timing here would move
    /// cut spans out from under existing edits.
    ///
    /// Confidence becomes 1.0: a human typed this, so the doubt-dimming the
    /// recognizer earned no longer applies. That also makes "which words did I
    /// fix" visible — corrected words render at full opacity.
    ///
    /// Empty or whitespace text is a NO-OP, not a removal: removing a word
    /// from the transcript is not an operation that exists — deleting what was
    /// SAID is `deleteWords`, which cuts the footage. A transcript word with
    /// no footage behind it would be a lie about the recording.
    func correctWord(id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var current = transcript,
              let index = current.words.firstIndex(where: { $0.id == id }),
              current.words[index].text != trimmed else { return }

        let snapshot = current
        undoManager?.registerUndo(withTarget: self) { $0.restoreTranscript(snapshot) }
        current.words[index].text = trimmed
        current.words[index].confidence = 1.0
        transcript = current
        applyAndSaveTranscript()
    }

    /// The transcript's twin of `restore(_:)`: whole-value snapshots, so undo
    /// is multi-level by construction and redo falls out of registering the
    /// current value on the way back.
    private func restoreTranscript(_ snapshot: Transcript) {
        guard let current = transcript else { return }
        undoManager?.registerUndo(withTarget: self) { $0.restoreTranscript(current) }
        transcript = snapshot
        applyAndSaveTranscript()
    }

    /// Chained onto the same save queue as EDL and event writes, so the three
    /// sidecars cannot interleave their failure handling — and a failed write
    /// reverts to the last value that IS on disk, exactly as event edits do.
    private func applyAndSaveTranscript() {
        guard let transcript else { return }
        let controller = self.controller
        let previousSave = pendingSaveTask
        outstandingSaves += 1
        pendingSaveTask = Task { @MainActor [weak self] in
            await previousSave?.value
            do {
                try transcript.write(to: controller.snittBundle)
                self?.lastSavedTranscript = transcript
            } catch {
                self?.transcriptEditWasRejected(error)
            }
            self?.outstandingSaves -= 1
        }
    }

    private var lastSavedTranscript: Transcript?

    private func transcriptEditWasRejected(_ error: Error) {
        transcript = lastSavedTranscript
        onEditRejected?(error)
    }

    /// Deletes words: their spans become cuts on the SAME EDL every other edit
    /// uses (D62's payoff). Undoable through the same whole-EDL snapshot as
    /// cuts, crop and gain, so a text deletion and a drag-cut interleave on one
    /// stack.
    func deleteWords(ids: Set<UUID>) {
        guard let transcript else { return }
        let selected = transcript.words.filter { ids.contains($0.id) }
        let ranges = TranscriptEditing.cutRanges(removing: selected, from: transcript)
        guard !ranges.isEmpty else { return }
        let current = edl
        undoManager?.registerUndo(withTarget: self) { $0.restore(current) }
        edl.cuts.append(contentsOf: ranges.map { Cut(range: $0) })
        applyAndSave()
    }

    /// Seeks the preview to where a word is spoken. Through `onScrub`, which
    /// already maps source time to the trimmed timeline and snaps a click
    /// inside a cut to the nearest kept edge.
    func seek(toWord word: TranscriptWord) { onScrub(word.start) }

    /// Sets one audio track's gain (M5f follow-on; `TrackState.gain` has
    /// existed and been applied by the export mix since M3 with no way to set
    /// it).
    ///
    /// Clamped at 0 and at 4x. Zero is mute-by-slider, which is legitimate;
    /// negative gain inverts phase, which is never what a slider drag meant.
    /// The ceiling is where a quiet recording can be rescued without the
    /// waveform becoming a solid block of clipping.
    func setGain(track: String, gain: Double) {
        let clamped = min(max(gain, 0), 4)
        guard let index = edl.trackStates.firstIndex(where: { $0.track == track }),
              edl.trackStates[index].gain != clamped else { return }
        let current = edl
        undoManager?.registerUndo(withTarget: self) { $0.restore(current) }
        edl.trackStates[index].gain = clamped
        applyAndSave()
    }

    /// Mutes or unmutes one audio track.
    func setMuted(track: String, muted: Bool) {
        guard let index = edl.trackStates.firstIndex(where: { $0.track == track }),
              edl.trackStates[index].muted != muted else { return }
        let current = edl
        undoManager?.registerUndo(withTarget: self) { $0.restore(current) }
        edl.trackStates[index].muted = muted
        applyAndSave()
    }

    /// The audio tracks this recording actually has, in draw order — the same
    /// derivation the timeline uses, so the controls and the bands cannot
    /// disagree about which sources exist.
    var audioTracks: [TrackState] {
        TimelineTrackLayout.audioTracks(in: edl.trackStates).compactMap { name in
            edl.trackStates.first { $0.track == name }
        }
    }

    /// Removes the crop entirely. Distinct from cropping to the full frame only
    /// in what reaches disk — `nil` writes no `crop` key at all.
    func resetCrop() {
        guard edl.crop != nil else { return }
        let current = edl
        undoManager?.registerUndo(withTarget: self) { $0.restore(current) }
        edl.crop = nil
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
    /// Waits for any in-flight save.
    ///
    /// The icon refresh on close reads `edit.json` back from disk, so it has
    /// to run after the save that produced it — otherwise it composes a poster
    /// from the EDL as it was BEFORE the user's last edit.
    func awaitPendingSave() async { await pendingSaveTask?.value }

    private func applyAndSave() {
        // Marked here, synchronously, NOT inside the save task below. The EDL
        // has already changed by the time this is called, and a user who cuts
        // and immediately closes the window would otherwise race the save: the
        // close reads this flag, finds it still false, and the icon keeps
        // showing material the recording no longer has. Cutting the dead end
        // off a take and closing straight away is a completely ordinary thing
        // to do.
        editsChangedTheRecording = true
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
struct TimelineViewRepresentable: NSViewRepresentable {
    @ObservedObject var state: EditorTimelineState
    let playhead: Double
    /// Surfaces a marker click up to `EditorContentView`'s own `@State`
    /// (Task 6) — unlike the other callbacks below, this one opens UI
    /// (a sheet), not a model mutation, so it does not belong on
    /// `EditorTimelineState` alongside `onSelect`/`toggleExpansion`/
    /// `removeCut`, which all mutate testable state directly.
    let onEditMarker: (UUID) -> Void

    func makeNSView(context: Context) -> TimelineView {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: 480, height: 56))
        // Set here as well as in `updateNSView` so the zoom buttons work from
        // the first render rather than only after the first update pass.
        state.timelineView = view
        view.onScrub = { [weak state] in state?.onScrub($0) }
        view.onSelect = { [weak state] in state?.onSelect($0) }
        view.onToggleExpansion = { [weak state] in state?.toggleExpansion(of: $0) }
        view.onRemoveCut = { [weak state] in state?.removeCut(id: $0) }
        // D50/D56 (M5f Task 6): a marker drag reports the OUTPUT time it was
        // dropped at, converted back to SOURCE time by `moveMarker` itself
        // (see that method's doc comment) — never converted here in the
        // untestable AppKit seam.
        view.onMoveMarker = { [weak state] id, outputTime in state?.moveMarker(id: id, toOutput: outputTime) }
        view.onEditMarker = onEditMarker
        return view
    }

    /// Deliberately a one-line delegation to `state.displayState(playhead:)`
    /// — the axis-mapping logic that matters lives there, where it is
    /// testable without AppKit or SwiftUI's runtime; this stays the thin,
    /// untestable seam.
    func updateNSView(_ nsView: TimelineView, context: Context) {
        state.timelineView = nsView   // also set in makeNSView; see there
        let display = state.displayState(playhead: playhead)
        nsView.update(duration: display.duration,
                     cuts: display.cuts,
                     markerPoints: display.markerPoints,
                     playhead: display.playhead,
                     selection: display.selection,
                     expandedCutIDs: display.expandedCutIDs,
                     trackStates: display.trackStates,
                     waveforms: display.waveforms,
                     filmstrip: display.filmstrip)
    }
}

/// SwiftUI shell around the `AVPlayerLayer` surface: play/pause controls, the
/// timeline, and a jump-point list. §4.7 puts the video surface — and, per
/// Task 6, the timeline's gesture handling — in AppKit while everything
/// around them stays SwiftUI.
struct EditorContentView: View {
    @ObservedObject var state: EditorTimelineState

    init(state: EditorTimelineState) { self.state = state }
    @State private var playhead: Double = 0
    /// Which marker the edit sheet is open for, if any (Task 6). UI-only,
    /// like `expandedCutIDs`'s spirit but one level further out: nothing
    /// tests WHICH marker is currently open in a sheet, only that
    /// `EditorTimelineState.updateMarker`/`moveMarker` persist and undo
    /// correctly — see those methods' own tests. This lives here, not on
    /// `EditorTimelineState`, because it is presentation state a SwiftUI
    /// runtime test cannot exercise anyway.
    @State private var editingMarkerID: UUID?
    /// Crop mode. UI-only, like `editingMarkerID`: what is asserted is that
    /// `applyCrop`/`resetCrop` persist and undo, not which mode a view is in.
    @State private var croppingActive = false

    private var controller: PreviewController { state.controller }

    /// What to say after an automatic trim.
    static func trimCaption(_ outcome: EditorTimelineState.DeepTrimOutcome) -> String {
        switch outcome {
        case .cut(let spans, let seconds):
            let unit = spans == 1 ? "span" : "spans"
            return String(format: "Cut %d %@, %.1fs", spans, unit, seconds)
        case .nothingToCut:
            return "No dead air found"
        case .notReady:
            // The distinction that matters: this is a WAIT, not an answer.
            return "Still loading the waveform"
        }
    }

    /// The marker the sheet below is editing, re-derived from
    /// `state.events` on every access rather than cached at click time — a
    /// concurrent edit (undo, another drag) must not let the sheet open on
    /// stale label/transcript text.
    private var editingMarkerBinding: Binding<LoggedEvent?> {
        Binding(
            get: { editingMarkerID.flatMap { id in state.events.first { $0.id == id } } },
            set: { newValue in editingMarkerID = newValue?.id }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
            // The chapter index, always present rather than conditional on
            // there being markers: it is now the only way to CREATE one
            // outside of recording, so hiding it when the list is empty would
            // hide the affordance exactly when it is needed.
            MarkerPane(state: state, playhead: playhead,
                       onEditMarker: { editingMarkerID = $0 })
                // 260, not 220: this replaced the full-width jump list at the
                // bottom of the window, and real marker labels are whole
                // descriptive sentences rather than the short names the
                // narrow column assumed.
                .frame(width: 260)
            Divider()
            PlayerLayerView(player: controller.player)
                .frame(minWidth: 480, minHeight: 270)
                .overlay {
                    // Only while cropping: an always-live drag layer would
                    // swallow clicks meant for the player.
                    if croppingActive {
                        CropDragOverlay(videoSize: controller.player.currentItem?.presentationSize
                                                   ?? CGSize(width: 16, height: 9)) { sub in
                            state.applyCrop(sub)
                            croppingActive = false
                        }
                    }
                }
            if state.transcriptionStatus != .none {
                Divider()
                TranscriptPane(state: state, playhead: playhead)
                    .frame(width: 250)
            }
            }
            // D56 (M5f Task 6): three stacked tracks — a thin marker lane
            // above, video, then audio — replacing the single undifferentiated
            // track Task 5 left behind. The taller frame (56, was 40) gives
            // the marker lane room to be a real click/drag target rather
            // than a sliver; see `TimelineView`'s own `markerTrackHeight`.
            TimelineViewRepresentable(state: state, playhead: playhead,
                                      onEditMarker: { editingMarkerID = $0 })
                // 120, was 56. The filmstrip and the two waveforms need real
                // vertical room: at 56 the video band was ~25px, which is
                // smaller than a thumbnail is useful at, and each audio band
                // was ~8px — enough to show a band exists, not enough to read
                // where the sound is.
                .frame(height: 120)
            // One row per audio source, matching the bands the timeline draws
            // above. Placed here rather than inside `TimelineView` because
            // that is a raw NSView with no room to grow controls without
            // competing with the waveform for the same few pixels — the same
            // reasoning that put the marker editor in a sheet.
            if !state.audioTracks.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.audioTracks, id: \.track) { track in
                        AudioTrackControls(
                            state: track,
                            onGain: { state.setGain(track: track.track, gain: $0) },
                            onMute: { state.setMuted(track: track.track, muted: $0) })
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }
            HStack(spacing: 12) {
                Button("Play") { controller.play() }
                Button("Pause") { controller.pause() }
                // D56 (M5f Task 4): the only place a selection becomes a
                // cut. Disabled with nothing selected — dragging alone no
                // longer cuts anything; this button is the deliberate
                // decision that does.
                Button("Cut") { state.cutSelection() }
                    .disabled(state.selection == nil)
                Divider().frame(height: 16)
                Button(croppingActive ? "Cancel Crop" : "Crop") { croppingActive.toggle() }
                Button("Reset Crop") { state.resetCrop() }
                    .disabled(state.edl.crop == nil)
                Divider().frame(height: 16)
                // D57's three presets, named for how much footage SURVIVES
                // rather than for how hard the trim tries.
                Menu("Auto-Trim") {
                    Button("Conservative") { state.autoDeepTrim(preset: .conservative) }
                    Button("Default") { state.autoDeepTrim(preset: .default) }
                    Button("Aggressive") { state.autoDeepTrim(preset: .aggressive) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Cut the spans where nothing happens")
                if let outcome = state.lastTrimOutcome {
                    // Said out loud, because a button that silently does
                    // nothing is indistinguishable from a broken one — and
                    // "nothing to cut" and "not loaded yet" are different
                    // answers that would otherwise look identical.
                    Text(Self.trimCaption(outcome))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // The affordance the zoom feature never had. `TrimGesture`'s
                // own comment names the density problem these solve: at
                // ~0.75s/pixel on a ten-minute recording a deliberate short cut
                // is silently swallowed.
                Button("−") { state.timelineView?.zoomOut() }
                    .help("Zoom the timeline out")
                Button("+") { state.timelineView?.zoomIn() }
                    .help("Zoom the timeline in")
            }
            .padding(8)
        }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            // 20Hz, raised from 10 when the playhead stopped being decoration.
            // It now selects which transcript word is highlighted, and the
            // recognizer emits words as short as 0.06s ("the", in this
            // project's first real recording) — at 10Hz those were skipped
            // entirely and the highlight jumped over them.
            //
            // The comment here used to say this value was "appearance only,
            // not asserted by any test", which stopped being true the moment
            // `TranscriptPlayhead` started consuming it.
            //
            // Still polling rather than `addPeriodicTimeObserver`: the observer
            // is the better mechanism, but it would not change what is on
            // screen, and the open question is the opposite one — whether
            // re-rendering a long transcript at this rate is affordable. That
            // needs a ten-minute recording to answer, and is in field-notes.
            let seconds = controller.player.currentTime().seconds
            playhead = seconds.isFinite ? seconds : 0
        }
        .sheet(item: editingMarkerBinding) { marker in
            MarkerEditSheet(label: marker.label ?? "", transcript: marker.transcript ?? "") { label, transcript in
                state.updateMarker(id: marker.id,
                                   label: label.isEmpty ? nil : label,
                                   transcript: transcript.isEmpty ? nil : transcript)
                editingMarkerID = nil
            } onCancel: {
                editingMarkerID = nil
            }
        }
    }
}

/// Mute and gain for one audio source.
///
/// `TrackState.gain` has existed and been applied by the export mix since M3
/// with no way to set it — the same shape crop had, a model feature with no
/// surface. The waveform above redraws as the slider moves, because
/// `WaveformScale` applies gain before scaling, so "how loud will this be"
/// is answered by looking rather than by exporting.
private struct AudioTrackControls: View {
    let state: TrackState
    let onGain: (Double) -> Void
    let onMute: (Bool) -> Void

    /// "microphone" is what the model calls it; "Mic" is what fits.
    private var displayName: String {
        switch state.track {
        case "microphone": return "Mic"
        case "systemAudio": return "System"
        default: return state.track
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { !state.muted }, set: { onMute(!$0) })) {
                Text(displayName)
                    .frame(width: 52, alignment: .leading)
            }
            .toggleStyle(.checkbox)

            Slider(value: Binding(get: { state.gain }, set: { onGain($0) }), in: 0...4)
                .frame(maxWidth: 220)
                .disabled(state.muted)

            // The number matters: "somewhere past halfway" is not a setting
            // anyone can return to deliberately.
            Text(String(format: "%.1f×", state.gain))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

/// The marker-edit UI (D50/D56, M5f Task 6): label plus transcript, the two
/// fields `EditorTimelineState.updateMarker(id:label:transcript:)` accepts
/// together.
///
/// A SHEET, not an inline field or a popover: `TimelineView` is a raw
/// `NSView` with no spare room to grow a second, always-visible editing
/// surface without competing with the marker track itself for the same few
/// pixels, and a popover would need this AppKit view's exact click point
/// translated into a SwiftUI anchor — real plumbing for a feature used
/// occasionally, not every frame. A modal sheet is the smallest addition on
/// top of a shell that is already SwiftUI (`EditorContentView`):
/// `.sheet(item:)` needs only a `Binding` and an `Identifiable` item, and
/// blocking the rest of the editor while a transcript — potentially a full
/// sentence, not just a short label — is being typed is the right default,
/// not an inline field a stray click elsewhere could abandon half-written.
private struct MarkerEditSheet: View {
    @State var label: String
    @State var transcript: String
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Marker").font(.headline)
            TextField("Label", text: $label)
                .textFieldStyle(.roundedBorder)
            Text("Transcript").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $transcript)
                .frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Save") { onSave(label, transcript) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
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
    /// Where an editor window opens: **centred, at 75% of the screen**.
    ///
    /// The previous fixed 640x420 opened small, wherever AppKit chose to
    /// cascade it. A timeline is a wide scrubbing surface — at 640pt a
    /// ten-minute recording is roughly 0.75 seconds per pixel, the density
    /// `TrimGesture` documents as the reason a deliberate short cut gets
    /// swallowed. Opening larger is the cheap half of that; zoom is the other.
    ///
    /// `visibleFrame`, not `frame`: it excludes the menu bar and the Dock, so
    /// 75% of it is 75% of the space a window can actually occupy.
    ///
    /// Pure and screen-free so it is testable — a test host has no screen and
    /// `NSScreen.main` is nil there. A nil or empty screen falls back to the
    /// old fixed size rather than guessing, keeping headless behaviour
    /// unchanged instead of inventing a geometry nobody can see.
    static func openingContentRect(on visibleFrame: NSRect?,
                                   scale: Double = 0.75) -> NSRect {
        guard let visibleFrame, visibleFrame.width > 0, visibleFrame.height > 0 else {
            return NSRect(x: 0, y: 0, width: 640, height: 420)
        }
        let width = visibleFrame.width * scale
        let height = visibleFrame.height * scale
        return NSRect(x: visibleFrame.minX + (visibleFrame.width - width) / 2,
                      y: visibleFrame.minY + (visibleFrame.height - height) / 2,
                      width: width,
                      height: height)
    }

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
        // Transcript (D62): load an existing one, or start making one. From
        // here rather than the state's init, so the TCC-gated recognizer is
        // never constructed as a side effect of a test building a state.
        state.loadTranscript()
        state.beginTranscriptionIfNeeded()
        let hosting = NSHostingView(rootView: EditorContentView(state: state))
        let window = NSWindow(
            contentRect: Self.openingContentRect(on: NSScreen.main?.visibleFrame),
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
        // The poster is drawn from the material the EDL keeps, so trimming a
        // dead lead-in — the single most common edit this app exists to make —
        // leaves the icon showing seconds the recording no longer contains.
        // Once per editing session, not once per edit: stamping is a
        // half-second job.
        if state.editsChangedTheRecording {
            state.editsChangedTheRecording = false
            let bundle = controller.snittBundle
            let state = self.state
            Task { @MainActor in
                await state.awaitPendingSave()
                _ = await RecordingIcon.stampInBackground(bundle: bundle).value
            }
        }
    }

    // MARK: - Edit menu: Cut Selection (Task 5)

    /// Whether this editor's timeline currently has something selected —
    /// the same condition that enables/disables `EditorContentView`'s Cut
    /// button. Read by `AppDelegate`'s `NSMenuItemValidation` conformance so
    /// the Edit ▸ Cut Selection menu item (Delete/Backspace, see
    /// `AppShell.editMenuItem`) is disabled with nothing selected — Task 5's
    /// own constraint: "a user with nothing selected must not be offered an
    /// action that does nothing". It is also what keeps the Delete key from
    /// swallowing an ordinary Backspace anywhere else in the app: the item
    /// is enabled only while THIS is true for the key window's editor, so a
    /// Backspace typed into, say, the export panel's filename field — a
    /// different window, or this editor's own window with nothing
    /// selected — falls through to normal text editing instead.
    var hasTimelineSelection: Bool { state.selection != nil }

    /// Edit ▸ Cut Selection (Delete/Backspace), Task 5's second requirement:
    /// "Task 4 added a Cut button but no keyboard path." `EditorWindowController`
    /// is not in the responder chain (see `AppDelegate.exportDocument`'s doc
    /// comment for why), so the menu item's nil target resolves to
    /// `AppDelegate`, which picks the key window's editor and calls this —
    /// the exact same decision `EditorContentView`'s Cut button already
    /// makes, just reachable without a mouse.
    func cutTimelineSelection() {
        state.cutSelection()
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

    /// Drives a complete select-then-cut exactly as a real drag ending
    /// followed by pressing Cut would (Task 7; D56/M5f Task 4 inserted the
    /// selection step), without a live `NSView` or SwiftUI runtime. Kept
    /// under its original `...TrimForTesting` name for the existing callers
    /// (`EditorExportTests`, `EditorPersistenceTests`) that only care about
    /// the resulting `Cut` landing in `state.edl`, not the selection D56
    /// interposed before it.
    func applyTrimForTesting(_ range: TimeRange) {
        state.onSelect(Selection(range: range))
        state.cutSelection()
    }

    /// Drives a real right-click ▸ Remove Cut (D56, M5f Task 5) exactly as
    /// `TimelineView.handleRemoveCutMenuItem` would, without a live
    /// `NSView`/`NSMenu`.
    func removeCutForTesting(id: UUID) {
        state.removeCut(id: id)
    }

    /// Drives a completed drag that only SELECTS — no Cut decision — exactly
    /// as `TimelineView.mouseUp` reporting a resolved drag would. Distinct
    /// from `applyTrimForTesting`, which selects AND immediately cuts: this
    /// exists for tests (`AppShellTests`'s Cut Selection menu validation)
    /// that need to observe `hasTimelineSelection` while something is
    /// selected but not yet turned into a `Cut`.
    func selectForTesting(_ range: TimeRange) {
        state.onSelect(Selection(range: range))
    }

    /// The in-memory EDL. Deliberately the ADJACENT property to the one
    /// `EditorPersistenceTests` cares about — see that suite's doc comments
    /// for why asserting only this would pass against the bug Task 7 fixes.
    func currentEDLForTesting() -> EditDecisionList {
        state.edl
    }

    /// The in-memory events, markers included — the events-side twin of
    /// `currentEDLForTesting()` (Task 6). Deliberately what tests assert
    /// against for a marker drag/edit's STORED result (SOURCE time, label,
    /// transcript), not `controller.jumpPoints`'s OUTPUT-time, display-only
    /// copy — the same adjacent-property trap `currentEDLForTesting()`'s own
    /// doc comment names, one field over.
    func currentEventsForTesting() -> [LoggedEvent] {
        state.events
    }

    /// Drives a real marker drag exactly as `TimelineView.mouseUp` reporting
    /// a resolved marker move would (Task 6), without a live `NSView`.
    /// `outputTime` matches `onMoveMarker`'s own parameter: OUTPUT time, the
    /// timeline's own drawing axis, converted back to SOURCE time by
    /// `EditorTimelineState.moveMarker` itself.
    func moveMarkerForTesting(id: UUID, toOutput outputTime: Double) {
        state.moveMarker(id: id, toOutput: outputTime)
    }

    /// Drives a real marker edit (label + transcript) exactly as saving the
    /// edit sheet would (Task 6), without live SwiftUI.
    func updateMarkerForTesting(id: UUID, label: String?, transcript: String?) {
        state.updateMarker(id: id, label: label, transcript: transcript)
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
