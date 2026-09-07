# M5f: The Editor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the editor good enough that "nobody liked it" would be a verdict on the product rather than on the UI.

**Architecture:** The timeline stops representing the *source* and starts representing the *export*. Cuts gain identity so they can be removed, and render as folds rather than overlays. Selection becomes state independent of cutting. Audio, video and markers get their own tracks. Then the model itself changes: cuts become per-track when sync is unlocked, and slice turns the EDL from "source minus ranges" into an ordered sequence of segments.

**Tech Stack:** AppKit (`NSView` drawing, `NSMenu` context menus), SwiftUI shell, AVFoundation composition, Swift 6 strict concurrency, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-02-snitt-design.md` — §4.4 (edit scope, expanded by D56), §7 (the `.snitt` document), §9 (data flow), §4.12 (markers). Decisions **D55, D56, D57** are the direct authority; **D50** (transcripts) and **D58** (why this precedes validation) constrain it.

## Why this milestone exists

v0.1.0 shipped. The product owner's judgement: *"Nobody will like this if the UI sucks."*

That is the same argument D45 made for the app shell — testing with a UI you do not intend to keep risks a "no" indistinguishable from a real one, which is the most expensive negative available because it looks like an answer. §13's first validation question is whether anyone prefers this trim/export loop to `Cmd+Shift+5`. A timeline that shows source duration, draws cuts as overlays you cannot remove, and has no selection is not that loop.

## Global Constraints

- **Two clocks, named at every boundary.** *Source time* is a position in `capture.mov`. *Output time* is a position in the export. This project has already shipped one defect from conflating them (M4b: the timeline fed output-time durations while the EDL consumed source-time cuts, so a second trim silently did nothing). **Every function taking a time takes a named type or says which clock in its signature.** A bare `Double` crossing this boundary is a defect.
- **`.snitt` bundles from v0.1.0 must still open.** The format is shipping. Any change to `edit.json` reads the old shape and writes the new one; a bundle that opened yesterday opens today.
- **`snitt trim` writes the same EDL.** The CLI is not a second model (§4.8, §6). Anything this milestone adds to the document, the CLI path must tolerate — at minimum by round-tripping it unharmed.
- **Non-destructive (§4.5).** Every operation here mutates the EDL. `capture.mov` is never rewritten.
- **Swift 6, strict concurrency, zero warnings** from `Sources/` under `swift build -Xswiftc -strict-concurrency=complete`.
- **Privacy in logging.** Two leaks in this project's history — an interpolated filename, and `String(describing:)` on an `NSError` (which serialises `userInfo` including `NSFilePath`). `privacy: .public` on `domain`, `code`, `localizedDescription` only. Use `SnittLog.logger(_:target:)`.

### Verification traps (apply to every task)

- `swift test` **exits 0 when the test bundle segfaults** — an inline `error: … signal code 11`, then **no summary line**. Piping to `grep` returns grep's status. **Only `Test run with N tests … passed/failed` is trustworthy; a run with no summary line is a crash.**
- `timeout` does not exist on macOS.
- **`NSApp` is nil in a test bundle** until `NSApplication.shared` is touched — `@Suite(.serialized)` with `init() { _ = NSApplication.shared }`, and `@MainActor` on the suite if it touches windows.
- **`.serialized` serialises within a suite only.** `EditorWindowTestGate.run { }` (in `EditorWindowController.swift`) is the global mutex for window-opening tests. Use it.
- **Every programmatically created `NSWindow` sets `isReleasedWhenClosed = false`.** The default is `true`, which is an over-release under ARC; it crashed shipped v0.1.0. `WindowLifetimeTests` pins it.
- No test may mutate the process-global cwd or write to the real preference domain — verify via the **mtime** of `~/Library/Preferences/com.impressiver.snitt.plist`.
- **Do not set `SNITT_SIGN_IDENTITY`** — leave `build/Snitt.app` on `Snitt Development` or the maintainer's Screen Recording grant is revoked.

### Testing standard

Every test names a plausible wrong implementation and is **verified to fail against it**. **Assert the target string was found before mutating, grep the mutated file before running, restore the tree afterwards.** That rule has caught four distinct failures here: a mutation matching nothing and reporting `passed`, a prescribed mutation that discriminated nothing, a `git checkout` that discarded uncommitted work, and a race test that passed for timing reasons.

**Twenty-six** adjacent-property findings so far. For this milestone the shape to watch is: **asserting a rectangle was drawn is not asserting the timeline represents the export.** Prefer assertions on the model — output duration, mapped times, the EDL after an operation — over assertions on pixels.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/SnittDocument/EditDecisionList.swift` | Cuts gain identity; per-track cuts; segment order. Reads the v0.1.0 shape. |
| `Sources/SnittDocument/Timebase.swift` *(new)* | `SourceTime` / `OutputTime` as distinct types, and the conversions between them. |
| `Sources/SnittDocument/TimelineGeometry.swift` | Maps **output** time to x, not source. |
| `Sources/SnittDocument/TimeRangeMapping.swift` | Source↔output conversion, non-monotonic once reordering lands. |
| `Sources/SnittDocument/Selection.swift` *(new)* | A selected span — UI state, not an edit. |
| `Sources/SnittApp/TimelineView.swift` | Tracks, folds, selection, context menus. |
| `Sources/SnittApp/EditorWindowController.swift` | Wires selection and cut/slice operations to the state. |
| `Sources/SnittApp/HotkeySettings.swift` *(new)* | D55: persisted combinations and re-registration. |
| `Sources/SnittExport/DeadAir.swift` *(new)* | D57: the dead-air detector and its presets. |
| `Sources/SnittCapture/HealthSampler.swift` | D57: extend the existing per-frame variance sampling. |

---

## Task 1: Two clocks, named

**Files:** Create `Sources/SnittDocument/Timebase.swift`; modify `TimeRangeMapping.swift`; test `Tests/SnittDocumentTests/TimebaseTests.swift`

**Why first:** every later task moves times across the source/output boundary. Doing this last means retrofitting it through six tasks of new call sites.

- [ ] **Step 1: Write the failing test**

```swift
@Test("Output time skips cut spans")
func outputTimeSkipsCuts() {
    // 10s source, one 2s cut at 3s. Output is 8s long.
    let edl = EditDecisionList(cuts: [Cut(range: TimeRange(start: 3, end: 5))])
    let base = Timebase(sourceDuration: 10, edl: edl)

    #expect(base.outputDuration == 8)
    // Before the cut: unchanged.
    #expect(base.outputTime(forSource: SourceTime(2)) == OutputTime(2))
    // After the cut: shifted back by the cut's length.
    #expect(base.outputTime(forSource: SourceTime(6)) == OutputTime(4))
    // Inside the cut: there IS no output time. Returning 0, or the cut's
    // start, or crashing are all wrong in different ways — a caller that
    // asks must be told the span is not in the output.
    #expect(base.outputTime(forSource: SourceTime(4)) == nil)
}

@Test("Source time round-trips through output time")
func roundTrip() {
    let edl = EditDecisionList(cuts: [Cut(range: TimeRange(start: 3, end: 5))])
    let base = Timebase(sourceDuration: 10, edl: edl)
    for t in stride(from: 0.0, to: 10.0, by: 0.25) {
        guard let out = base.outputTime(forSource: SourceTime(t)) else { continue }
        // The property M4b's defect violated: a time that survives the cut
        // must map back to itself. Asserting only one direction passes
        // against an inverse that is subtly wrong.
        #expect(abs(base.sourceTime(forOutput: out).seconds - t) < 1e-9)
    }
}
```

- [ ] **Step 2: Run it, watch it fail** — `swift test --filter TimebaseTests`
- [ ] **Step 3: Implement** `SourceTime` and `OutputTime` as distinct `Sendable` wrappers over `Double`, and `Timebase` holding the conversions. **Do not make them interchangeable** — no shared protocol with a `.seconds` both satisfy in a way that lets one be passed where the other is expected. The type system is the guard here.
- [ ] **Step 4: Verify.** Mutation: make `outputTime(forSource:)` return the raw value unshifted. `outputTimeSkipsCuts` must fail.
- [ ] **Step 5: Commit** — `feat(edit): name the two clocks`

---

## Task 2: Cuts get identity, and the document keeps opening

**Files:** modify `EditDecisionList.swift`; test `Tests/SnittDocumentTests/EditDecisionListTests.swift`

**Why:** "right-click this cut and remove it" needs something to address a cut *by*. `TimeRange` is `{start, end}` — two cuts of the same length at the same place are indistinguishable, and there is no handle to delete.

**The format is shipping.** v0.1.0 wrote `edit.json` with `cuts: [{start, end}]`. That shape must still load.

- [ ] **Step 1: Write the failing test**

```swift
@Test("A v0.1.0 edit.json still opens")
func readsLegacyCuts() throws {
    // The exact shape v0.1.0 wrote. If this test needs changing, the format
    // broke — that is what it is for.
    let legacy = """
    {"schemaVersion":1,"cuts":[{"start":1.0,"end":2.0}],"tracks":[]}
    """
    let edl = try JSONDecoder().decode(EditDecisionList.self, from: Data(legacy.utf8))
    #expect(edl.cuts.count == 1)
    #expect(edl.cuts[0].range == TimeRange(start: 1, end: 2))
    // Every cut has an id even when the file had none — otherwise the UI
    // cannot address cuts in a bundle recorded before this milestone.
    #expect(edl.cuts[0].id != nil)
}

@Test("Two identical spans are distinguishable cuts")
func identicalSpansAreDistinct() {
    let a = Cut(range: TimeRange(start: 1, end: 2))
    let b = Cut(range: TimeRange(start: 1, end: 2))
    // Value-equal ranges, different cuts. Without this, removing one removes
    // both, and the fold UI cannot tell which one was clicked.
    #expect(a.id != b.id)
}
```

- [ ] **Step 2–5:** run-fail; implement `Cut { id: UUID, range: TimeRange }` with a custom `Decodable` that mints ids for legacy entries; verify; **mutation: decode legacy cuts into an empty array — `readsLegacyCuts` must fail**; commit.

**Check `snitt trim` round-trips a bundle written by the GUI and vice versa**, and say in the report what you observed. §6 makes the CLI the same model, not a second one.

---

## Task 3: The timeline shows the export

**Files:** `TimelineGeometry.swift`, `TimelineView.swift`; test `Tests/SnittDocumentTests/TimelineGeometryTests.swift`

**Why:** `TimelineGeometry(width:duration:)` is handed **source** duration today, so a cut leaves the timeline the same length with a red patch in it. D56's first requirement is that a cut *shortens* the timeline.

- [ ] **Step 1: Write the failing test**

```swift
@Test("A cut shortens the timeline")
func cutShortensTimeline() {
    let edl = EditDecisionList(cuts: [Cut(range: TimeRange(start: 2, end: 4))])
    let base = Timebase(sourceDuration: 10, edl: edl)
    let geometry = TimelineGeometry(width: 800, timebase: base)

    // The whole point: 8s of output across the full width, not 10s.
    #expect(geometry.duration == 8)
    // The end of the source maps to the end of the view.
    #expect(abs(geometry.x(atOutput: OutputTime(8)) - 800) < 0.001)
    // A source time inside the cut has no x — it is not in the export.
    #expect(geometry.x(atSource: SourceTime(3)) == nil)
}
```

- [ ] **Step 2–5:** run-fail; re-express geometry over `Timebase`; verify; **mutation: feed it `sourceDuration` — `cutShortensTimeline` must fail**; commit.

---

## Task 4: Selection is not a cut

**Files:** create `Sources/SnittDocument/Selection.swift`; modify `TrimGesture.swift`, `TimelineView.swift`, `EditorWindowController.swift`; test `Tests/SnittAppTests/SelectionTests.swift`

**Why:** dragging currently *is* cutting. D56 separates them: a drag selects (transparent blue), and cutting is an operation applied to a selection.

- [ ] Selection is UI state and is **not** persisted to the EDL — it survives no reopen, and nothing in `edit.json` records it.
- [ ] A cut applied to a selection produces one `Cut` covering it and clears the selection.
- [ ] **Test the separation directly:** dragging must leave the EDL unchanged. A test that only checks a cut appears after "drag then cut" passes against the old conflated behaviour.
- [ ] Colour: `NSColor.systemBlue.withAlphaComponent(…)`. Pick the alpha against the existing track fills in `TimelineView.draw` and say what you chose.

---

## Task 5: Cuts are folds, not gaps

**Files:** `TimelineView.swift`, `EditorWindowController.swift`; test `Tests/SnittAppTests/CutFoldTests.swift`

**Why:** D56 — a cut collapses to a red line with its edges touching; clicking expands it in place on transparent red; an expanded cut still contributes **nothing** to duration and is still skipped in playback; right-click removes it.

- [ ] **The trap:** expansion is a *view* state. An expanded cut must not change `Timebase.outputDuration`, must not change where the playhead maps, and must not become part of the export. **Test that expanding a cut leaves output duration unchanged** — that is the assertion that separates a fold from an un-cut.
- [ ] Playback with a cut expanded still skips the span. Assert against the composition, not the drawing.
- [ ] Right-click → **Remove Cut** restores the segment: output duration grows by the cut's length, and the EDL loses exactly that `Cut` by id.
- [ ] Removing a cut is undoable through the same `UndoManager` Task 7 of M5c installed, and persists like any other edit.

---

## Task 6: Three tracks

**Files:** `TimelineView.swift`; test `Tests/SnittAppTests/TrackLayoutTests.swift`

- [ ] Video and audio render as separate tracks; **cuts are synchronised across them by default.**
- [ ] Markers get their own thinner track **above** both.
- [ ] Markers are **moveable** (drag along the timeline, in output time, mapping back to source for storage) and **editable** — label plus the transcript field D50 defines.
- [ ] Editing a marker persists like a cut does. **Assert the marker's source time after a drag**, not its x position: a marker that moves on screen and not in the document is the M4b defect wearing a different hat.

---

## Task 7: D55 — customizable hotkeys

**Files:** create `Sources/SnittApp/HotkeySettings.swift`; modify `SettingsWindowController.swift`, `main.swift`; test `Tests/SnittAppTests/HotkeySettingsTests.swift`

**Why it is cheap:** `HotkeyCombination` already carries `keyCode` and `modifiers`, and `HotkeyMonitor(combination:)` already takes one. `.defaultCombination` is just a static.

- [ ] Persist a combination per action (record, marker); default to today's ⌥⌘5 / ⌥⌘M.
- [ ] A key-recorder control in the Settings window M5c shipped.
- [ ] **Re-register on change**, and surface failure the way `main.swift:112` already does — a combination another app owns must say so, not fail silently.
- [ ] **Test that a changed combination is the one registered**, not merely that it was stored. Storing without re-registering is M5b's R22 defect in a new place.

---

## Task 8: D56 Tier 2 — per-track cuts

**Files:** `EditDecisionList.swift`, `TimelineView.swift`; tests

- [ ] Right-click a cut → **Unlock A/V Sync**, after which audio and video cuts move independently.
- [ ] The EDL's `cuts` becomes per-track. **The v0.1.0 format still opens** (Task 2's rule): a legacy global cut loads as a synchronised pair.
- [ ] `snitt trim` must round-trip a per-track EDL without flattening it. Check and report.

---

## Task 9: D56 Tier 2 — slice and reorder

**Files:** `EditDecisionList.swift`, `TimeRangeMapping.swift`, `CompositionBuilder.swift`, `MarkerMapping.swift`, `TimelineView.swift`; tests

**Read this before starting.** This is the task that changes what an edit *is*. Today the EDL means *"the source, minus these ranges"* — order is implicit and time maps monotonically forward. Slice-and-reorder makes it *an ordered sequence of segments*, and **every downstream mapping assumes the monotonicity you are removing**: `TimeRangeMapping`, `MarkerMapping`, `CompositionBuilder`, and D51's subtitle burn-in timing.

- [ ] Slice cuts at a point without removing anything, producing two adjacent segments.
- [ ] Segments can be reordered; the export follows segment order.
- [ ] **Markers follow their segment.** A marker at source 7s inside a segment moved to the front is now near the start of the output. Assert its *output* time after a reorder — this is where non-monotonic mapping either works or silently does not.
- [ ] Slice is synchronised across audio/video by default, unlockable like cuts.
- [ ] **Verify the export matches the timeline** for a reordered EDL, end to end. §9 makes preview and export share one builder; reordering is the first thing that could break that guarantee in a way a still frame would not reveal.

---

## Task 10: D57 — auto-deep-trim

**Files:** create `Sources/SnittExport/DeadAir.swift`; modify `HealthSampler.swift`; CLI and app surfaces; tests

**A span is dead air only when all hold:** audio is background noise only, video is pixel-identical, no mouse or keyboard events, no marker, and **no subtitle still owed reading time**.

- [ ] **Extend `HealthSampler`'s existing per-frame variance** rather than adding a decode pass. It already samples during the `AVAssetWriter` pass for §12.1; post-hoc detection means decoding the whole movie again.
- [ ] Presets **conservative / default / aggressive** in the app; the same flag plus per-criterion flags in the CLI.
- [ ] **Agent recordings log no OS input by construction** (D49) — so for an agent demo the input criterion is always satisfied and frame-change detection decides alone. D44 warned this could see one long gap and delete the entire recording. **Test exactly that case**: an agent-initiated bundle with no input events must not be trimmed to nothing.
- [ ] Auto-trim produces ordinary `Cut`s — so Task 5's folds make every automatic decision inspectable and individually removable, rather than a bulk edit accepted whole.

---

## Definition of Done

- [ ] A cut shortens the timeline; the timeline's length is the export's length.
- [ ] Selecting and cutting are separate; selection is blue, cuts are red folds.
- [ ] Clicking a fold expands it without changing duration or playback; right-click removes it and the segment returns.
- [ ] Audio, video and markers are separate tracks; markers move and edit, and persist.
- [ ] Hotkeys are configurable, and a conflicting combination says so.
- [ ] A/V sync unlocks; slice and reorder work, and the export matches the timeline.
- [ ] `auto-deep-trim` runs at three presets and never empties an agent recording.
- [ ] **A `.snitt` written by v0.1.0 still opens**, and `snitt trim` round-trips whatever the GUI writes.
- [ ] Full suite green twice with the trustworthy summary line; strict-concurrency clean.

## Deliberately not in scope

- **Transitions, effects, titles, multi-clip import** — §4.4 is trim, cut, mute, and now order. Not an NLE.
- **Waveform rendering** in the audio track — useful, and a separate piece of work.
- **Burned-in subtitle rendering** (D51) — deferred by D52 with the rest of the export UI.
