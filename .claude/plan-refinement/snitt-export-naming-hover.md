# Plan refinement ledger — snitt-export-naming-hover

artifact: in-chat plan (no doc), restated in "The plan" below
slug: snitt-export-naming-hover
session: d42cd016-2375-43b3-a942-7012aa6a077d
opened: 2026-10-30

## Run parameters

- tier: full loop. 5 personas (default engineering roster), cross-exam capped
  2 rounds/item, 2 passes max.
- consent mode: auto-accept verified factual corrections only; every design
  tradeoff goes to the menu.
- model-policy: main line Opus (session default), personas Sonnet.
- Phase 0 note: warm-started from the sibling ledger `snitt-editor-ui.md`
  (different artifact, same subsystem). Three of its decisions bear on this
  plan and were re-verified rather than trusted: D12 (cross-lane collision
  test written first), D13 (CI excludes SnittAppTests), D17 (undo is a binding
  constraint near `onScrub`). See Phase 2 F4/F5.

## The plan

Three independent PRs. Product-owner directions already settled by question
(do not re-litigate the *what*; the *how* is open):

1. **Export destination remembers the last-used folder, seeded at `~/Downloads`.**
   Today `EditorWindowController.defaultExportURL(forBundle:)` puts the export
   beside the `.snitt` bundle. New: resolve from a remembered folder, default
   `~/Downloads`, remembered across launches. Proposed name
   `LastExportDirectory` (`Sources/SnittApp/`), key
   `com.impressiver.snitt.lastExportDirectory`. Write the memory on a
   *successful export*, not on picking a folder in the chooser, so
   "Change… then Cancel" is not remembered. Fall back to `~/Downloads` when
   the remembered folder is gone or unwritable.

2. **Bundle filename leads with the recorded app and window title.**
   `App-Title-branch-commit-timestamp.snitt`. New signature
   `BundleNaming.filename(app:windowTitle:git:timestamp:)`, fed at
   `RecordingCoordinator.swift:617` from `target.descriptor.applicationName`
   and `.title`. Rules: collapse hyphen runs (new); drop the title *whole*
   (never truncate) when it is empty after sanitising, duplicates/prefixes the
   app name, or exceeds a 40-char cap; keep the existing 200-byte assembled cap
   with branch truncated first, commit and timestamp never.

3. **Hovering the filmstrip previews that position; leaving snaps back.**
   Only while paused; filmstrip (video) band only. New
   `TimelineView.onHoverPreview: (Double?) -> Void` (source seconds, nil on
   exit) driven by an `NSTrackingArea` over `TimelineTrackLayout.bands(...).video`.
   New transient path on `EditorTimelineState` that seeks *without* pausing and
   *without* writing `pendingSeekTarget`; on exit, seek back to the committed
   position. Click behaviour and `onScrub` untouched.

## Phase 2 — grounding the plan's own claims

| ID | Claim | Verdict | Evidence |
|----|-------|---------|----------|
| F1 | Export currently defaults beside the bundle, by documented intent | **CONFIRMED** | `EditorWindowController.swift:3515` `defaultExportURL(forBundle:)`; doc comment: *"Beside rather than in Movies or Downloads because a `.snitt` bundle already lives where its owner put it, and the export belongs with the thing it was made from."* Pinned by `ExportSheetTests.swift:92` asserting `/Users/somebody/Desktop/Standup.mp4`. |
| F2 | A second doc comment also asserts export ignores the recordings folder | **CONFIRMED** | `SettingsWindowController.swift:157`: *"Export deliberately does not consult it — `defaultExportURL(forBundle:)` puts an export beside the bundle it came from."* PR 1 makes this false; both comments must change or they become lies. |
| F3 | The recorded app name and window title are in hand where the bundle is named | **CONFIRMED** | `RecordingCoordinator.swift:617` calls `Self.bundleURL(...)` with `target` in scope; `ResolvedTarget.descriptor` is a `CaptureTargetDescriptor` carrying `applicationName` (`CaptureTarget.swift:23`) and `title` (used at `:633` as `target.descriptor.title`). No new plumbing through the capture layer needed. |
| F4 | CI does not run the tests PRs 1 and 3 would add | **CONFIRMED** | `ci.yml:172` runs `swift test --filter 'SnittDocumentTests\|SnittCaptureTests\|SnittAutomationTests\|SnittCLITests\|SnittMCPTests'`. The step's own comment: SnittExportTests and SnittAppTests *"HANG on a GitHub-hosted runner"* — 254 tests never returned, job killed at 37 min. So *"export, composition, the editor and the timeline are verified LOCALLY ONLY."* PR 2 (SnittCaptureTests) **is** covered; PRs 1 and 3 (SnittAppTests) are **not**. |
| F5 | TimelineView has no hover/tracking machinery today | **CONFIRMED** | No `updateTrackingAreas`, `NSTrackingArea`, `mouseMoved`, `mouseEntered` or `mouseExited` anywhere in `TimelineView.swift`. Overrides present: `layout`, `scrollWheel`, `magnify`, `keyDown`, `mouseDown`, `mouseDragged`, `mouseUp`, `menu(for:)`, `draw`, plus AX. |
| F6 | Clicking the timeline pauses playback by design | **CONFIRMED** | `EditorTimelineState.onScrub` (`:492`) calls `controller.pause()` and sets `pendingSeekTarget`. Doc comment: *"Scrubbing STOPS playback (D87)."* So hover must NOT route through `onScrub`, or crossing the timeline would stop the picture and overwrite the position to snap back to. |
| F7 | The filmstrip band rect is already pure and testable | **CONFIRMED** | `TimelineTrackLayout.bands(in:markerHeight:audioTracks:hasTranscript:)` returns `(marker, video, audio, transcript)` rects; `TimelineView.draw` (`:1679`) and `drawFilmstrip` (`:1691`) use `bands.video`. `TimelineTrackLayoutTests` exists. So the tracking rect needs no new geometry. |
| F8 | Hover handlers are directly testable without a window server | **CONFIRMED** | `GestureMatrixTests.swift:119` etc. drive `view.mouseDown(with: .synthetic(at:in:clickCount:))`. The same helper drives `mouseMoved`/`mouseExited`. |
| F9 | `pendingSeekTarget` exists because the player's clock lies during an in-flight seek | **CONFIRMED** | `EditorWindowController.swift:575-592`: *"Every seek in this editor hands the work to a `Task`, so `player.currentTime()` still reports the OLD position for a beat afterwards."* `currentOutputSeconds` (`:630`) reads `controller.player.currentTime()` directly. So reading "the committed position" at hover-enter has a real race. |
| F10 | The CLI needs no change | **CONFIRMED** | `snitt-cli/main.swift:219` documents `snitt export <bundle> --format mp4\|gif --out <path>`; `:428` resolves `out` unconditionally. No default to change. |
| F11 | A mutation-testing gate exists | **CONFIRMED** | `Scripts/mutate.sh`; sibling ledger D15 records that a SKIP counts as a failure and anchors are four-field literals. Any new pure function added by these PRs is in scope for it. |

## Phase 3 — Important findings (Phase 7 precondition: fires, 4 items)

- **I1 (Important).** PR 1 reverses a documented, reasoned decision (F1) and
  falsifies a second comment (F2). The *what* is a product-owner direction and
  settled. Open: whether "sticky" is worth a new piece of persisted state with
  its own stale/missing-folder failure mode, versus a plain `~/Downloads`
  constant; and the write trigger (on choose vs on successful export).
- **I2 (Important).** PR 2 writes window titles into filenames. Snitt's own MCP
  instructions warn that a window title *"routinely name[s] accounts, orders and
  internal tools"*. A filename is more durable and more widely surfaced than a
  frame: Finder screenshots, PR attachments, `ls` in a recorded terminal, and
  the bundle name is what gets shared. Load-bearing unverified assumption: that
  a 40-char cap plus app-name dedup is adequate mitigation, and that no opt-out
  is needed.
- **I3 (Important).** PR 3 adds AVPlayer seeks at mouse-move frequency to a view
  whose gesture-priority rules are documented as repeatedly regressed
  (`TimelineView.swift:1183-1195` records a measured seven-assertion failure
  from one y-gate deletion). Sibling ledger D12 required a cross-lane collision
  test *written first* for exactly this class. Plus the F9 race on restoring the
  committed position, and no coalescing design yet for 60Hz seeks against an
  async zero-tolerance `AVPlayer.seek`.
- **I4 (Important).** F4: PRs 1 and 3 ship with zero CI signal. Verification is
  local-only, which makes the local run the gate and raises the cost of a
  regression that only reproduces on someone else's machine.

## Decision log

_(appended as the Decider rules; see Phase 7)_

## Phase 7 — persona returns (pass 1)

Roster: Principal Engineer, Red team, Operator, Product/UX, Pragmatist, plus a
Privacy/data-exposure specialist added to own I2. Decider inline.

### Verified by the Decider before recording (never delegated)

- **P-PRIV-1 — CONFIRMED, and stronger than the plan's own I2.** The codebase
  already has a settled, documented policy that a raw captured window title
  never leaves the machine, and PR 2 as specced reverses it.
  *Chain, every hop checked:* (1) `RecordingMetadata.swift` has no `title` or
  `applicationName` field at all, so the title is NOT in `meta.json` today
  (`grep -n "title\|applicationName"` returns nothing); (2) `AuditRecord.target`
  (`AuditRecord.swift:24`) does carry the raw title, but that log lives at
  `~/Library/Application Support/Snitt/audit.jsonl`, outside any bundle;
  (3) `DiagnosticsBundle.swift:156-195` `redactingTarget`/`hashedTarget`
  replaces it with a per-export **salted** SHA256 on the export path only,
  because "§5.1's own worked example of why window-scoping matters is a window
  titled 'Mail Password Required' — exactly the kind of string this bundle
  promises never to carry", and the salt is "never written to the file" so a
  guess is unverifiable; (4) `DiagnosticsBundleTests.swift:194-230` pins it.
  So the filename is the one path that would carry the title unredacted into
  the artifact that is *designed* to be shared.
- **P-PRIV-2 — CONFIRMED as reasoning (the plan's own rules entail it).** A
  40-char cap and app-name dedup are truncation, not redaction: "Mail Password
  Required" is 23 characters and passes both checks untouched. Content-blind
  length limits do not reduce information content.
- **P-UX-1 — CONFIRMED.** `TimelineView.swift:1865-1867` draws exactly ONE
  playhead bar, from the stored `playhead` property (`:294`, output time,
  assigned at `:403` from the editor's committed position). The plan's hover
  path moves the picture while that bar stays put and draws nothing at the
  hover x, so the view would visibly disagree with itself.
- **P-OPS-1 — CONFIRMED.** `RecordingCoordinator.prepareOutputDirectory`'s doc
  comment rejects exactly the failure class PR 1 proposes to adopt: "Refuses ...
  rather than silently substituting the default ... A person who deliberately
  pointed recordings at, say, an unmounted external volume would be badly
  surprised — possibly days later ... A clear, visible failure they can act on
  ... beats a silent redirect every time."
- **P-OPS-2 — CONFIRMED, and independently raised by the Decider before the
  panel returned (uncontested, no cross-exam).** `docs/DEVELOPING.md:69-73`:
  "`swift build` and `swift test` do not touch `build/Snitt.app`, so a green
  suite proves nothing about what the running app does." With F4 (CI runs no
  SnittAppTests), a passing local suite is not evidence either PR 1 or PR 3
  works on screen.
- **P-PRAG-1 — PARTIALLY REFUTED. The alternative mechanism does not hold.**
  The Pragmatist proposed replacing hover-seeks with the already-decoded
  filmstrip frames, calling them "full-resolution". They are not.
  `FilmstripSampler.sample` defaults are `maxFrames: 120, height: 64`, and the
  editor's only call site (`EditorWindowController.swift:354`) passes **no
  arguments**, so it takes both defaults. `count = max(1, min(maxFrames,
  Int(duration.rounded(.up)) * 2))`, so a 10-minute recording gets 120 frames
  over 600s = **one frame per 5 seconds**, each **64px tall**, and the
  generator's tolerance is +/- interval/2 so a frame is not even accurate to
  its own nominal time ("A filmstrip wants speed, not frame accuracy").
  That cannot drive the main video surface and cannot aim precisely. The
  mechanism is refuted; the persona's *second* point survives intact.
- **P-PRAG-2 — CONFIRMED and adopted.** PR 3 bundles two separable surfaces
  with different risk: hover geometry/tracking (pure, testable via the existing
  synthetic-event helper, F7/F8) and hover-driven playback mutation (I3's
  risk, F9's race). Split them.

### Phase 5b — own-ledger recurrence: a shape has hit three times

Three independent findings share one shape: **the plan resolves a failure or
exposure class the opposite way from an existing, documented decision in the
same codebase, without noting the contradiction.**

1. P-OPS-1 — silent fallback vs `prepareOutputDirectory`'s documented refusal.
2. P-PRIV-1 — raw title in a shared filename vs `DiagnosticsBundle`'s
   documented salted-hash redaction of that exact field.
3. F2 — PR 1 silently falsifies `SettingsWindowController.swift:157`.

Three hits means patching instances is off the table (Phase 5b). Structural
guard adopted: **for every default, policy or name these PRs change, the PR
body must quote the existing doc comment that governs it and state explicitly
whether the change upholds or reverses it.** This repo keeps its decisions in
doc comments rather than ADRs, so a reversal that does not update the comment
is indistinguishable from a bug, and the comment is the only place a reviewer
would find the prior reasoning. `shape: documented decision reversed without
updating the comment that records it`.

### Late returns, verified by the Decider

- **P-RED-1 — CONFIRMED, and this is the strongest evidence in the review.**
  The project already treats the bundle FILENAME ITSELF as a leak surface
  needing redaction, for the same reason PR 2 would make worse.
  `RecordingCoordinator.swift:723-740`: *"The bundle's FILENAME is redacted
  deliberately: BundleNaming derives it from the git branch and commit, so a
  branch called `feat/acme-corp-integration` would name a customer or an
  unreleased feature — and this line is collected verbatim into `snitt
  diagnostics export`, which people attach to public support threads (§5)."*
  The same comment records a **measured** leak of that filename via
  `NSError.userInfo`'s `NSFilePath`. So the filename is a known, already-
  patched leak path, and PR 2 proposes adding a window title to it.
  Converges with P-PRIV-1 on independent evidence: two personas, no overlap.
- **P-RED-2 — CONFIRMED.** `setZoom` (`TimelineView.swift:944-961`) funnels
  `zoomIn`/`zoomOut`/`scrollWheel`/`magnify`, calls `rebuildGeometry()`, and
  references nothing mouse-related. Zooming or scrolling under a stationary
  pointer changes time-per-pixel with no hover re-fire.
- **P-ENG-1 — CONFIRMED.** A tracking area fixed at layout time goes stale.
  `update(duration:...audioLanes:...)` ends at `:418-419` with
  `rebuildGeometry(); needsDisplay = true`, and `update(phrases:)`
  (`:719-722`) with `needsDisplay = true` alone. Neither invalidates tracking
  areas, and `layout()` (`:422`) is the only path AppKit's own
  `updateTrackingAreas()` trigger coincides with. Both `audioLanes` and
  transcript presence change `bands(...).video`'s height
  (`TimelineTrackLayout.swift`: `videoHeight` is a function of
  `audioTracks.count` and `hasTranscript`).
- **P-ENG-2 — CONFIRMED against my own read of the file.** `BundleNaming`'s
  200-byte truncation is POSITIONAL on a two-slot `[branch, commit]` layout:
  `:44-51` branches on `parts.count == 2`, treats `parts[1]` as the commit and
  truncates `parts[0]`. Prepending app and title makes `parts` up to four
  long, so "truncate the branch first" silently becomes "truncate the app
  first". The plan also gave `app` no cap at all, so a long
  `localizedName` could consume the whole budget. This is a hole in the
  plan as written, not in the existing code.

## Phase 7 — triage and rulings

Important: I1 (export fallback), I2 (window title), I3 (hover risk),
I4 (no CI signal), plus P-UX-1 (no hover affordance) and P-ENG-2 (budget
restructure). Small, parked: the `LastExportDirectory` name (kept); writing
the memory on successful export rather than on folder-choose (kept).

Cross-examination rounds run: **zero, deliberately.** Every Important item
resolved as either uncontested-on-independent-evidence or decidable on a fact
the Decider could check directly, so spending rounds would have bought
nothing. Noted in Caveats.

- **D1 — PR 2 drops the window title; the app name stays.** `Decided`,
  recommendation to the product owner (their earlier pick was "app and title
  lead", made before P-PRIV-1/P-RED-1 existed, so the revisit gate is
  satisfied: new evidence contradicts a fact the choice rested on). Carried by
  the Privacy specialist and Red team independently. *Given:* no `title` field
  in `RecordingMetadata`; `DiagnosticsBundle.swift:156-195` salted-hashes that
  exact field on the export path with `DiagnosticsBundleTests:194-230` pinning
  it; `RecordingCoordinator.swift:723-740` already redacts the filename and
  records a measured `NSFilePath` leak of it. An app name ("Safari", "Xcode")
  is a fixed low-entropy string; a window title is the field this codebase
  treats as its most sensitive. `shape: documented decision reversed without
  updating the comment that records it`.
- **D2 — a missing or unwritable remembered export folder falls back to
  `~/Downloads` ONLY if the sheet says a substitution happened; otherwise
  refuse.** `Decided`. Reconciles Operator (refuse, per
  `prepareOutputDirectory`) with Product/UX (a visible fallback is fine)
  without overriding either. *Given:* `ExportSheet.swift:471` renders only
  `destination.deletingLastPathComponent().lastPathComponent`, so a fallback
  from `/Volumes/Big/demos` to `~/Downloads` displays "Downloads" and is
  indistinguishable from having chosen it. The Operator's objection survives a
  bare fallback; a one-line note in the sheet answers it.
- **D3 — rule on the CLASS, not the two instances: any geometry change while
  a hover preview is live CANCELS the preview (snaps back).** `Decided`.
  Phase 5b: P-RED-2 (zoom/scroll) and P-ENG-1 (lane count, transcript) are two
  hits of one shape — *the hover point-to-time mapping has invalidation
  triggers that are not mouse events.* Cancel-on-change is chosen over
  recompute-from-cached-point because it adds no new state and this file's own
  comments record repeated gesture regressions. Cost: zooming while aiming
  drops the preview until the next mouse move.
- **D4 — PR 3 splits into 3a (tracking area, hover marker, geometry; no
  player mutation) and 3b (the transient seek path).** `Decided`, carried by
  the Pragmatist's second point. *Given:* F7/F8 make 3a pure and testable with
  the existing synthetic-event helper; 3b is the half carrying I3's risk and
  F9's race. Different review surfaces.
- **D5 — the Pragmatist's filmstrip-frame alternative is rejected on facts.**
  `Decided`. See P-PRAG-1: 64px-tall frames, one per 5s on a ten-minute
  recording, and deliberately not frame-accurate. It also would not satisfy
  the stated requirement, which presupposes playback moved and must snap back.
- **D6 — `BundleNaming.filename` is restructured to labeled-field budgeting,
  and the app name gets an explicit cap.** `Decided`, carried by the Principal
  Engineer. *Given:* P-ENG-2.
- **D7 — `Scripts/make-app.sh` plus a hands-on check is a required step for
  all three PRs, not an optional nicety.** `Decided`, uncontested (raised by
  the Operator and independently by the Decider). *Given:* F4 plus
  `docs/DEVELOPING.md:69-73`.
- **D8 — structural guard (Phase 5b, three hits): every PR body quotes the
  doc comment governing each default/policy/name it changes and states whether
  it upholds or reverses it.** `Decided`. See the Phase 5b entry above.

## Phase 8 — blind spots

| Dimension | Disposition |
|---|---|
| Accessibility | Hover is pointer-only by construction. **Explicitly out of scope:** it previews a navigation `keyDown` already reaches, so no capability becomes keyboard-inaccessible. `TimelineAccessibility` exists precisely because the timeline's pixels were unreachable, so this is a deliberate call, not an oversight. |
| Undo | Hover must register NO undo. Sibling ledger D17 made undo a binding constraint and there are `registerUndo` sites adjacent to `onScrub`; a transient preview that lands on the undo stack would be a defect. Asserted by test in 3b. |
| Performance | Unresolved by design until 3b: coalescing 60Hz `mouseMoved` against an async zero-tolerance `AVPlayer.seek`. 3a does not have this problem, which is part of why the split is worth it. |
| Migration | New `UserDefaults` key only; absent reads as `~/Downloads`. No bundle-format change, no `schemaVersion` bump. Existing `.snitt` names are untouched (PR 2 affects new recordings only). |
| Rollback | No kill switch exists or is appropriate: local app, ship a build. |
| i18n / concurrency / teardown | Not engaged by any of the three. |
| Observability | No telemetry by design. D7 (hands-on check) is the only feedback channel, which is why it is mandatory rather than optional. |

## Termination

**Condition 1, converged**, after one pass. The pass produced no Important item
left unsettled, the Phase 0 conformance walk was clean (fresh ledger, nothing
to drift), and the one whole-approach alternative offered (P-PRAG-1) was
refuted on verifiable facts rather than parked. Budget used: 6 persona
sub-agents, 0 cross-exam rounds, well inside the 2-pass box.

Verdict: **Proceed**, with PR 2's mechanism reduced (D1). The three goals all
stand; no pivot, no kill.

## Convergence handoff — product owner selections (2026-10-30)

All menu items accepted as recommended. Final shape, four PRs:

- **PR 1** sticky export folder. `LastExportDirectory`, default `~/Downloads`,
  written on a SUCCESSFUL export only. A missing/unwritable remembered folder
  falls back to `~/Downloads` **and the sheet states the previous folder was
  unavailable** (D2). Both reversed doc comments updated (F1, F2).
- **PR 2** `App-branch-commit-timestamp.snitt`. **No window title** (D1).
  `filename` restructured to labeled-field budgeting with an explicit app cap
  (D6).
- **PR 3a** tracking area + hover marker + geometry. No player mutation.
  Tracking area rebuilt in `updateTrackingAreas()`, called explicitly from
  `apply(_:)` and `update(phrases:)` (P-ENG-1). Geometry change while hovering
  cancels the preview (D3).
- **PR 3b** the transient seek path: seek without pausing, without writing
  `pendingSeekTarget`, restore the committed position on exit, no undo
  registration, coalesced seeks.

Cross-cutting, all three: `Scripts/make-app.sh` + hands-on check before done
(D7); every PR body quotes the doc comment it upholds or reverses (D8).

Status: all decisions `Decided`. Loop closed, converged after one pass.

## Post-handoff additions (found while implementing PR 2)

My Phase 2 grepped `docs/*.md` but not `docs/superpowers/specs/`, which the PR
template names as the home of binding decisions. Three findings from it, none
of which reverse a decision above:

- **F12 — the Step 0 gate is a standing product-owner ruling, not just a
  sibling-ledger entry.** `docs/superpowers/specs/2026-09-10-snitt-rev5-ui.md:596`:
  *"Step 0 — write the collision test BEFORE any other change, and let it
  decide the item's shape. This is a hard gate (product-owner ruling,
  2026-09-10)."* Its reasoning is that a directive about DRAWING silently
  becomes a change to GESTURES, since right-click and double-click already
  reach a cut from every lane and only single click is y-gated, and
  `TimelineView.swift:536` states the hazard: *"an ungated full-height hit
  swallows clicks meant for each of them, three times over."* This independently
  confirms sibling D12 from a more authoritative source. **Binds PR 3a:** the
  collision test is written first and decides the shape. Shape of the test:
  hover at an x inside EACH lane and assert the preview fires only in the
  filmstrip band, plus assert every lane's existing single-click meaning is
  unchanged.
- **F13 — the hover marker has an assigned palette token already; do not
  invent one.** The same spec's token table (`:87`) assigns
  `signalBright #FFB84D` to "hover / selected mark", with hover washes at
  "120ms in / 180ms out, ease-out" (`:199`). `SnittPalette.signalBright` exists
  (`Sources/SnittBrand/SnittPalette.swift:76`) and `TimelineView.Palette`
  already draws the playhead from `SnittPalette.playheadInk` (`:1629`), which
  is near-white. So the hover marker is amber against a near-white playhead,
  which is distinguishable without resorting to a dashed line. Supersedes the
  menu option's "lighter or dashed" wording, which was my invention.
- **F14 — D8 is not a new guard; it is already the repo's stated requirement.**
  `.github/pull_request_template.md`: *"If a `docs/superpowers/specs/` decision
  says otherwise, say so here and argue it. Decisions are sticky, not frozen,
  and reversing one silently leaves the next reader with a premise that is no
  longer true."* The template also already requires *"Every new test names a
  plausible wrong implementation and was verified to fail against it"* and a
  full local `swift test` for editor/timeline changes. So D7 and D8 are
  compliance with existing policy, not additions. Recorded honestly rather
  than claiming credit for inventing them.
- **F15 — PR 2 upholds spec D20 rather than reversing it.** `D20 | Git context
  in meta.json + bundle name (§7), M2 | ... | Decided` (design spec `:1898`).
  PR 2 keeps branch and commit in the name and prepends the app, so the
  provenance story D20 bought is intact. Nothing to argue in the PR body on
  this point beyond saying so.

## Correction (2026-10-30, during PR 2 implementation)

I reported PR 2's full local gate as passing. **It had failed.** The run
printed `1145 of 2346 tests ran across both passes`, `MISMATCH`, and
`TEST GATE: FAILED`, and I claimed green off the per-target summary lines
without reading the verdict. My shell command also ended in `tail`, so the
harness surfaced the pipeline's exit 0 rather than the script's exit 1.

Root cause of the failure itself was NOT the change. `SnittAppTests`
segfaulted mid-run (`swiftpm-testing-helper` SIGSEGV, EXC_BAD_ACCESS at 0x0,
crashing image `SnittAppTests`, 16:14:57) because I ran a full
`swift build --build-tests` in a sibling worktree while the gate's
AVFoundation-heavy pass was running — exactly the contention
`Scripts/run-tests.sh`'s own header documents ("both are the AVFoundation-heavy
targets and they contend"). Re-run with nothing concurrent:
`2346 of 2346 tests ran across both passes`, `TEST GATE: PASSED`, including
`SnittAppTests` 1201 tests. Run alone beforehand it also passed 1201/1201, so
the change was never implicated.

Two things this exposes that the ledger should carry:

- **F16 — the gate's crash check has a hole the reconciliation covers.**
  `run_pass` fails on a missing summary via `if [ -z "$summary" ]`, but
  `$summary` is the grep across the WHOLE pass, so one target crashing while
  siblings print summaries leaves it non-empty. Only the
  `counted -ne expected` reconciliation catches that. The reconciliation is
  therefore load-bearing, not a tidiness check, and its verdict line is the
  only trustworthy signal.
- **F17 — the mutation pass is required for PR 3a, by the script's own
  header.** `Scripts/run-tests.sh:19-24`: mutation "asks would anything fail
  if the code were wrong... Run it before merging a change to geometry,
  hit-testing or wording." PR 3a is a hit-testing change. `Scripts/mutate.sh
  Tests/mutants.txt` is a separate gate and is not covered by a green
  run-tests.sh.

Saved as a memory (`snitt-test-gate-verdict-line`) so the reporting error does
not recur.

## Shipped (2026-10-30)

| PR | Branch | Gate |
|----|--------|------|
| #239 a bundle is named after the app it recorded | `feat/bundle-name-identifies-the-app` | 2346/2346, 3 hand mutants killed |
| #240 exports default to ~/Downloads | `feat/export-remembers-the-folder` | 2349/2349, 7/7 mutants |
| #241 hovering the filmstrip shows where you are pointing | `feat/filmstrip-hover-preview` | 2345/2345, 5/5 mutants |
| #242 a filmstrip hover previews the frame | `feat/filmstrip-hover-seeks` | 2354/2354, 3/5 (2 parked) |

#241 and #242 are a registered `gh stack` (stack #243), not a hand-rolled
`--base`: #242 consumes #241's `onHoverPreview` and cannot stand without it.

### What the implementation changed about the plan

Three things the loop did not catch, found only by building it:

- **F12/F13 came from `docs/superpowers/specs/`, which Phase 2 never read.**
  The PR template names it as the home of binding decisions. The Step 0
  collision-test gate is a standing product-owner ruling there, and the hover
  marker had an assigned palette token (`signalBright`) that the menu's
  "lighter or dashed" wording would have overridden with an invention.
- **The Step 0 test overturned the plan's own mechanism.** D4/the menu put
  the lane gate in the `NSTrackingArea` rect. Writing the test first showed
  the rect can gate nothing a test can reach and goes stale on two update
  paths, so the gate moved into the handler and the tracking area became an
  event-delivery optimisation. This is exactly what the ruling exists for.
- **The mutation run falsified two of my own test claims.** A test asserting
  only that playback continued survived deleting the `isPlaying` guard, and
  the coalescing guard turned out not to be what protects the seek count.
  Both are now either strengthened or parked with measurements.

### Process failures worth carrying forward

- I reported PR 2's gate as passing when it had printed `TEST GATE: FAILED`
  (see the Correction section above). Saved as the memory
  `snitt-test-gate-verdict-line`.
- I ran `Scripts/mutate.sh` against the whole 259-entry spec instead of the
  new lines, and had to kill it; an interrupted mutation run left a mutant in
  `TimelineGutter.swift`, which `git status` caught. Check the tree after any
  interrupted mutation run.
- A timing-based test wait passed in isolation and failed only under the full
  suite's contention. The project's `waitFor…` seam pattern is the answer,
  not a longer timeout.

Status: all decisions `Decided` and shipped. Loop closed.
