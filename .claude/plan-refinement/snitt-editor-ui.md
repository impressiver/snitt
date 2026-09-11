# Plan refinement ledger — snitt-editor-ui

artifact: scratchpad/snitt-ui.html (published artifact rev 2, "The recording, front and centre")
slug: snitt-editor-ui
session: 8fd6e671-e28f-467e-9499-f4343d7b1d09
opened: 2026-09-09

## Run parameters

- tier: full loop. 5 personas (design/product roster per product-owner direction,
  not the default engineering roster), cross-exam capped 2 rounds/item, 2 passes max.
- consent mode: auto-accept verified factual corrections only; every design
  tradeoff goes to the menu.
- model-policy: main line Opus (session default), personas Sonnet.

## Phase 2 — grounding the proposal's own claims

| ID | Claim in the proposal | Verdict | Evidence |
|----|----------------------|---------|----------|
| F1 | "Eleven controls in one flat row" | **REFUTED** | `EditorWindowController.swift:1286-1345`. Actual top-level controls: Rewind, Play, Pause, Cut, Crop, Reset Crop, Auto-Trim, −, + = **9**; **10** while cropping (Apply Crop is conditional on `croppingActive`). The three Auto-Trim presets are inside a `Menu`, not in the row. Count asserted, never counted. |
| F2 | "the recording gets under 60% [of the window]" | **OVERSTATED** | `:1250` gates the 250pt `TranscriptPane` on `transcriptionStatus != .none`. With transcription: 1200−510 = 690 ≈ 57%. Without it: 1200−260 = 940 ≈ **78%**. The claim is true only in the transcribed case and was stated unconditionally. |
| F3 | "TimelineView pins itself dark and deliberately stops following the appearance" | **CONFIRMED, and stronger than stated** | `TimelineView.swift:906-925`. Two reasons given: a fixed bug (label colours used as background fills), and a deliberate one — *"A timeline is a dark surface in every editor that has one, because the content on it — waveforms, thumbnails, cut marks — is what should carry the colour."* Also names a concrete hazard: *"on a fixed dark ground, a `labelColor` playhead would be black-on-black under a light system theme."* |

## Phase 3 — Important findings (Phase 7 precondition)

- **I1 (Important).** The product owner has directed light/dark support. The codebase
  carries a documented, reasoned decision that the timeline surface does NOT follow
  the appearance (F3). These conflict. Resolving it is not a styling choice — it
  decides whether "support light/dark" means the whole window or the window minus
  the timeline. Contested by construction → goes to the panel.
- **I2 (Important).** The word lane (D89) is the proposal's novel mechanism and is
  self-described as unvalidated at real word counts (~1,500 words for a 10-minute
  narration). Unverified load-bearing assumption.
- **I3 (Important).** The proposal removes the transcript from a persistent pane and
  demotes it to a toggle, which changes the surface for a shipped D62 gesture
  (select a phrase → delete → cut those seconds).

## Decision log

_(appended as the Decider rules; see Phase 7)_

## Auto-applied (verified factual corrections, consent gate satisfied)

- **A1 — control count corrected.** "Eleven controls in one flat row" → "Nine ... becoming
  ten while cropping". Rests on F1. `shape: asserted count, never counted`.
  Applied 2026-09-09. Reversible, CONFIRMED, touches no scope or mechanism, no live tradeoff.
- **A2 — window-share claim conditionalised.** "the recording gets under 60%" → "~78%
  before transcription, ~57% after", with the reason the pane is conditional stated.
  Rests on F2. `shape: unconditional claim about conditional UI`.
  Applied 2026-09-09. NOTE: this weakens the proposal's founding complaint; the red-team
  persona was explicitly asked whether the redesign still earns its cost given F2.

## Phase 7 — persona returns

### Design Critic (red team)

**RT-1 — the founding complaint is conditional.** Same shape as F2, independently found.
Argues item 1 ("the change the rest assume") is sold on a problem that mostly doesn't
exist, and should be re-justified on narrower merits (chapters legibility, timeline
gaining full width) or demoted to ride with item 7. confidence: high. **Triage: Important**
— it changes the build order.

**RT-2 — the proposal contradicts itself on theming.** CONFIRMED, and the strongest
finding of the pass. The proposal keeps the video well dark with the rationale "content
should carry the colour", then spends build item 3 overturning the *identical* rationale
for `TimelineView` — the surface that literally draws the waveforms, thumbnails and marks
that rationale names. Never explains why the two differ.

Verified independently by the Decider:
- `Tests/SnittAppTests/TimelinePaletteTests.swift` — `surfacesDoNotFollowTheAppearance`
  asserts `background`, `audioBand` and `playhead` resolve identically under `.aqua` and
  `.darkAqua`. **Light/dark for the timeline means deleting a passing test**, not restyling.
- `TimelineView.swift:933-943` — a deliberately tuned dark ramp: background `grey(0.13)`,
  videoBand `0.17`, audioBand `0.22`, markerLane `0.26`, separator `0.34`, playhead `0.97`.
  A light resolution means re-deriving all of it.
- The test file's own header says it exists to prevent a specific prior bug: label colours
  used as background fills, inverting and going illegible.

confidence: high. **Triage: Important, and contested** — it collides with an explicit
product-owner directive ("support light/dark out of the gate"). Decider does NOT rule
this; it goes to the user as a menu item. `shape: directive vs tested invariant`.

## Auto-applied (continued)

- **A3 — masthead framing corrected.** "gives the thing you're actually demonstrating
  less than half of it" → the picture shrinks when you transcribe. Same basis as A2;
  the earlier correction fixed the table row and missed the standfirst. Applied 2026-09-09.
  `shape: correction applied at one site, not all sites`.

### Cross-examination round 1 — "the timeline's lane budget" (contested)

Positions: PD wants a bounded, proportional stack (picture protected). NLE wants a
**sixth** lane for folds. HP wants a **taller** marks lane for label text. RT wants
fewer lanes than the proposal already has. All three want the same vertical space.

**Decisive evidence, verified inline by the Decider** (`TimelineView.swift:414-431`):

- `markerHit(at:)` is y-gated — `guard point.y <= markerTrackHeight` — and its doc
  comment says why: *"unlike `foldHit(atX:)`, which spans the whole view height because
  a fold's line is drawn full-height on purpose (one collapse across the whole
  synchronised stack) ... this y-gate is what keeps the two tracks' gestures from
  colliding."*
- `foldHit(atX x: Double)` takes **no y** at all. Folds are deliberately full-height.

This decides it. Folds being full-height is a *feature* (one collapse across a
synchronised stack), and the marker lane already needed a y-gate to survive it. Adding
Mic / System / Words lanes below Video means an ungated, x-only, full-height fold hit
will swallow clicks aimed at every new lane — the same collision, three more times.

**RULING (Decider).** Neither proposal as stated. Folds keep their full-height *visual*
line, and their *hit region* is y-gated to the filmstrip band — exactly the pattern
`markerHit` already uses. Zero lane cost, collision fixed, symmetric with shipped code.
- NLE's correctness finding is upheld; its lane cost is not paid.
- RT's "needs dedicated hit-testing ≠ needs dedicated vertical space" is **wrong on the
  facts** — full-height is deliberate, so hit geometry and vertical extent are coupled
  here. But its conclusion (no sixth lane) is carried, for a different reason.
- PD's "a rect can be hit-tested precisely while drawn inside another lane" is right in
  principle and is what the ruling implements.
- `shape: gesture collision from ungated hit region` — the third instance in this view.

**Evidence-quality note.** PD's round-1 answer cited the proposal's own figcaption
(`snitt-ui.html:489`) as evidence that folds already have a home — circular, since that
figcaption is the disputed claim and NLE had already refuted its stated rationale. One
instance only; PD's primary finding was independently verified against code and stands.

**Convergence on collapse order** — all three who answered agree, unprompted:
Words hides first → Mic+System merge to one composite → Marks labels truncate →
Video/filmstrip is protected last. Recorded as **uncontested**.

**HP position** (relayed via its completion notice, not received directly — caveat noted):
concedes the fold lane, concedes the chapters rail is not redundant, and refines its
marks-label ask to a **height-neutral "current mark" readout** rather than a taller lane.

### RULING REVISED — fold lane (supersedes the ruling above)

The first ruling ("no lane; y-gate folds to the filmstrip band") rested on a premise the
Accessibility persona then refuted with arithmetic that nobody else had done:

- Floor is **24×24pt** (WCAG 2.2 SC 2.5.8 AA), not Apple's 44pt comfort guidance.
- 731pt window × 35% = 256pt, minus ~84pt fixed overhead (padding + transport + ruler)
  = ~172pt for lanes. At 28pt/lane (24 + 4 gap): **6 lanes fit at 35%, 7 at 40%.**
- Proposed set is 5 lanes. Adding folds makes 6. **It fits.**

The budget objection is therefore false, and both personas who opposed the lane (PD, RT)
opposed it on that budget premise. Two personas support it on *independent* grounds:
NLE (eliminates the gesture collision rather than relocating it) and Accessibility
(one canvas region disambiguating two meanings is where 2.5.8's spacing exception fails
first, and where the eventual AX-element mapping is hardest to build correctly).

**Revised ruling: folds get their own thin lane, y-gated.** The earlier ruling relocated
the ambiguity into the filmstrip band rather than removing it — a distinction the
Accessibility return made explicit and the Decider had missed.

Revisit gate satisfied: new evidence contradicting a fact the prior ruling rested on.
Flip count for this item: 1. Prior ruling marked **Superseded**, not erased.

### Additional verified defect — shipped, not proposal-only

`TimelineView.swift:411` — `markerTrackHeight = min(14.0, bounds.height * 0.4)`. The
shipped marker lane is **14pt**, smaller than the 16px the persona inferred from the
proposal's CSS, against a 24pt enforceable floor — and markers are draggable. This is a
live accessibility defect in the shipped app, found incidentally by the panel.
`shape: hit target below enforceable floor`.

### Termination

Condition 3 — the countable box is spent: 5 personas, 1 cross-exam round as budgeted,
all Important items ruled or promoted to the menu. Verdict: **Proceed, scope narrowed.**
No persona argued for Kill; the red team explicitly said "rescope, don't drop".

---

# PASS 2 — 2026-09-09

## Phase 0 — conformance walk

conformance: 2026-09-09 · **CLEAN**

24 mechanical checks against the ledger's Decided entries — every ruling and every
auto-applied correction verified present in the artifact:

- D1 theming (chrome-only): `.mock .tl` re-pins dark tokens; section rewritten; the test
  named. D2 lane budget: ~35–40% bound, `TimelineTrackLayout` named, collapse order.
  D3 fold lane: present in markup, `foldband` class gone, reversal explained via
  `foldHit(atX:)`. D4 mark readout present. D5 transcript reflows, "does not slide in
  over" stated. D6 tokens re-tuned (old hexes appear only in the "Was" column, not in
  CSS); no opacity encoding. D7 keyboard + VoiceOver stated. D8 shipped 14pt defect
  recorded, proposal's own lane at 24px. D9 Show All Lanes. D10 export is item #1.
  A1/A2/A3 corrections all hold. HUD two-state + drawn glyphs. NLE-2 zoom tiers.

One check flagged and dismissed as a **false positive**: a grep for `⏸`/`⏹` in the body
hits the CSS comment and the figcaption that *explain why shapes replaced them* — both
documentation, not rendered buttons. Recorded here because a crude check that reports
drift where there is none is itself a defect in the walk.

## Phase 7 (pass 2) — satisfaction round

All five personas **resumed** with retained context rather than re-spawned, so each
judges its own finding. Each asked for: verdict (SATISFIED / PARTIALLY / NOT), residual,
and — the load-bearing question for a second pass — **whether any pass-1 fix introduced
a new problem**.

Personas were also told where I ruled AGAINST them (PD on the fold lane, RT on the
"category error" rebuttal) and invited to push back, so the round is not a rubber stamp.

## Pass 2 returns

| Persona | Verdict | Residual | New problem introduced by a pass-1 fix |
|---|---|---|---|
| Head of Product | **SATISFIED** | none on HP-1/HP-2 | none |
| Design Critic (red team) | PARTIALLY | none — both findings resolved in the authoritative text | **Duplicated sections + a stale build order** |
| NLE Interaction | PARTIALLY | lane arithmetic was a uniform-24pt simplification | **Marks and Folds are byte-identical containers** |
| Principal Designer | PARTIALLY | PD-1's **width** axis untouched (rail still fixed 228pt) | **Theming pin over-reaches onto the transport row** |
| Accessibility | *(pending)* | | |

### P2-1 — duplicated sections and a stale build order (red team). CONFIRMED, my bug.

Verified: three `<h2>` headings appeared twice, and the second Build order table was the
pre-review one — export back at #4, and item 3 still "Light + dark token set … real work
in `TimelineView`". It sat *after* the corrected table and *before* "What the review
changed", so a linear reader met the fix, then the bug, then a summary claiming the bug
was fixed.

Root cause, mine: the build-order rewrite spliced `s[:start] + new + s[end:]` where
`start` was the Build-order section and `end` the Accessibility section — but
Accessibility had been inserted *earlier* in the document, so `end < start` and
everything between them was duplicated rather than replaced.

**Why the Phase 0 conformance walk missed it:** every check asserted *presence* of new
content. `body.index("Export pre-flight sheet") < body.index("Two-zone layout")` passed
on the first occurrence of each and never looked for a second. Fixed by adding a
uniqueness assertion over all `<h2>`s.
`shape: edit verified by presence, never by absence of the old` — related to pass 1's
A3 (`correction applied at one site, not all sites`). **Second instance of the family;
naming the class per Phase 5b.** The structural guard is the uniqueness check, now
standing.

### P2-2 — Marks and Folds byte-identical (NLE). CONFIRMED.

`.markers` and `.foldlane` were both `height:24px;background:var(--m-panel-2)`, adjacent,
separated only by amber ticks vs a blue pill — colour as sole carrier, which is the exact
failure the document's own accessibility section flags without noticing it applied to
itself. Introduced *by* the fold-lane fix. **Applied:** the fold lane takes its own
blue tint plus an inset hairline.

### P2-3 — lane arithmetic overstated (NLE). CONFIRMED, my error.

"Six lanes fit at 35%" assumed every lane was 24pt. Real stack: 24+24+36+26+26+22 plus
4pt gaps = **178pt**. At 35% of a 731pt window, 172pt is available — it does **not** fit;
at 40%, 208pt, it does. **Applied:** the section now states 40% as the working number and
35% as where the first collapse fires, with the arithmetic shown.

### P2-4 — theming pin over-reaches (PD). CONFIRMED.

`.mock .tl{…}` re-pins dark tokens on the whole timeline container, so `.tl-bar` — the
transport cluster, time field, mark readout, zoomer — inherits them, contradicting prose
that said the transport follows the appearance. Visible in the document's own light/dark
figure.

**Ruling: the prose was wrong, not the CSS.** The transport is drawn inside the timeline
and drives the playhead that lives there; theming it would wedge a light strip between
light chrome above and dark lanes below. The line is drawn at the panel, not inside it.
Both prose sites corrected.

### P2-5 — width axis untouched (PD). Accepted.

The height bound protects the picture from the lanes; nothing protected it from the fixed
228pt chapters rail. **Applied:** a width-axis subsection — the rail collapses to a
timecode strip under pressure before the picture gives up width, and the layout needs a
stated, unit-tested minimum window size.

### Open, not applied

- **HP's secondary tension:** the HUD is described as "the differentiator nobody else
  offers" yet sits 7th of 9, behind corrective work invisible to a first-time user.
  Not raised in HP's original findings and it is a genuine sequencing tradeoff, so it
  goes to the product owner rather than being ruled here.

### P2-6 — HUD accessibility unspecified (Accessibility). CONFIRMED.

Two gaps, both from the HUD being designed *after* the keyboard/VoiceOver requirement
was written, so the requirement's scope never grew to cover it:

1. Only Mark showed a shortcut (⌥⌘M); pause, resume and stop had none stated anywhere.
2. The AX commitment ("marks, folds and the playhead become real accessibility elements")
   was scoped to the timeline only — and the HUD is explicitly "non-activating, floating,
   never key". **A panel that never becomes key cannot be tabbed to.**

That second point is a real conflict between two binding constraints, not an oversight:
§4.11 forbids stealing focus while recording; accessibility requires every control be
reachable without a pointer.

**Applied.** The resolution follows from §4.11 rather than working around it: the HUD's
buttons are the *visible reminder* of global hotkeys, not the primary path. Every control
mirrors to a hotkey registered the way the record hotkey already is — ⌥⌘M mark, ⌥⌘P
pause/resume, ⌥⌘. stop — reachable with no focus at all, and printed on the buttons so
the HUD teaches the keys. Because nothing focuses it, state changes post accessibility
notifications instead of relying on focus, so a VoiceOver user hears "Recording paused"
when it happens. The shortcuts join D84's registry, so Help ▸ Keyboard Shortcuts lists
them and cannot drift.

`shape: requirement written before the surface it must cover` — worth watching; any
new surface added after pass 1 inherits none of pass 1's requirements automatically.

Also recorded: Accessibility independently recomputed all six contrast pairs against the
real backgrounds and matched the Decider's figures exactly (4.75 / 4.89 / 4.87 / 9.92 /
13.58 / 13.01). Two independent computations agreeing is the strongest evidence in this
ledger.

## Termination — pass 2

Condition 1, **converged**, with one caveat stated rather than hidden:
- Phase 0 conformance walk was clean (24 checks), and its one miss (duplicate detection)
  is now closed by a structural guard.
- All five personas returned. One SATISFIED, four PARTIALLY — every "partially" was a
  NEW problem introduced by a pass-1 fix, all six now CONFIRMED and applied.
- No persona argued Kill or Pivot in either pass.
- Zero design decisions remain contested between personas.

**Verdict: PROCEED.** One genuine tradeoff goes to the product owner rather than being
ruled here: the HUD's position at #7 in the build order against its description as the
one differentiator competitors lack.

**What this loop did NOT cover** (per the skill's own handoff rule): this is the light,
memory-carrying pass over a *design document*. It has verified claims against the
codebase; it has not reviewed any implementation, because none exists yet. When this
produces code, that goes to /code-review, not back through Phase 3.

---

# PASS 3 — 2026-09-10 — artifact changed

**artifact:** `docs/superpowers/specs/2026-09-10-snitt-rev5-ui.md` (PR #89, branch
`docs/rev5-ui-spec`). Rev 5 is the character/branding pass over rev 4's shipped
structure. Slug deliberately UNCHANGED — same lineage, and rev 5 reverses two rev-4
rulings, which must record as `Superseded` rather than be silently re-decided.

**Run parameters:** full loop, 5 personas, cross-exam ≤2 rounds, ≤2 passes.
Consent: auto-accept verified factual corrections only; design tradeoffs to the menu.
model-policy: main line Fable 5 (above Opus; no switch), personas Sonnet.

## Phase 0 — conformance walk vs the rev-4 ledger

conformance: 2026-09-10 · **2 REVERSALS, both product-owner-directed, both recorded**

- **D3 fold lane** (pass-1 revised ruling: "folds get their own thin lane, y-gated").
  Rev 5 §5 retires it. **Flip count now 2 — the two-flip cap.** Revisit gate: the
  qualifying change is a product-owner directive, not new evidence, and the directive's
  own rationale ("cuts collapse the timeline entirely") is CONFIRMED by the code. The
  *decision* is the product owner's to make and is not re-litigated here. What IS in
  scope is the consequence the directive does not address — see I1.
  Prior ruling marked **Superseded**, not erased.
- **Word lane deferral** (rev 4: measured, deliberately unbuilt). Rev 5 W14 builds it
  via a tier model. Qualifying change: the tier model answers the exact objection the
  deferral rested on (one zoom level is a lie at real word counts). Reversal accepted.
- **P2-4 transport theming** — rev 5 W2 *implements* the rev-4 ruling rather than
  reversing it. No drift.
- **Rail width**: rev-4 ledger said 228pt; code says `chaptersRailWidth = 260`
  (`EditorWindowController.swift:1836`). Rev 5 says 260. **The spec is right and the
  old ledger entry was stale** — no action on the spec.

## Phase 2 — grounding rev 5's own claims

| ID | Claim | Verdict | Evidence |
|----|-------|---------|----------|
| G1 | W1 migrates the timeline palette: background/videoBand/audioBand/separator/playhead + waveform | **INCOMPLETE** | `TimelineView.swift:1288-1301` also defines `markerLane = grey(0.26)` and `audioBandMuted = grey(0.155)`. Neither appears in W1's migration list — two neutral greys would survive in a navy instrument. |
| G2 | `FoldPalette.base = NSColor.systemRed` | **CONFIRMED** | `FoldPalette.swift:29`. Note its doc: states differ "in weight, never in colour" — rev 5's redBright selected variant is a lightness change, consistent. |
| G3 | Editor window styleMask lacks `.fullSizeContentView`; `window.title` is set | **CONFIRMED** | `EditorWindowController.swift:1905-1910` |
| G4 | `StatusItemPresentation` has symbolName/title/isStopEnabled; apply sets image+title | **CONFIRMED** | `StatusItemController.swift:54-58, 333-340` |
| G5 | **"`foldHit(atX:)` takes no y"** as the basis for full-height cuts | **TRUE BUT NOT THE HIT PATH** | Two functions exist: `foldHit(at point:)` (`:541`) **y-gates** via `foldLaneRange` (`:542`, `:495`), and `foldHit(atX:)` (`:664`) does not. The shipped hit path is the y-gated one — rev 4's revised ruling *shipped*. Removing the lane removes that gate. |
| G6 | Lane stack becomes **150pt** (24+36+26+26+22 + 4×4) | **REFUTED** | `TimelineLaneBudget`: `preferredAudioHeight = 44` (not 26), `transcriptLaneHeight = 30` (not 22). Code's own `naturalHeight` minus the fold lane = 24+36+88+30 = **178pt**. The spec's arithmetic uses the rev-4 *document's* aspirational heights, not the shipped constants. |
| G7 | W4: "Plumb through `RecordingCoordinator` — it already carries the recording's state" | **REFUTED** | `grep TrackState` across `RecordingCoordinator.swift` and all of `Sources/SnittCapture/` returns **nothing**. `TrackState` is an EDL concept (`EditDecisionList.swift:90-95`). No record-time plumbing exists; W4 needs a new cross-layer path. |
| G8 | W12: "Auto-trim already classifies… extract *its* audio-silence decision" (one rule) | **REFUTED — there are two** | `AutoDeepTrim.swift:155` (per-track thresholds) and `SpeechChunker.swift:43,82` (`silenceFraction = 0.08`, `max(absoluteSilenceFloor, referenceLevel × fraction)`). The spec assumes a single extractable rule and does not say which. |
| G9 | `GainMeter` unity lands on segment 8 of 12 | **CONFIRMED** | recomputed independently from the published constants: (0−(−24))/36 × 12 = 8 |
| G10 | `recordRed` = 0.933/0.267/0.267 equals `RecordingIcon.recordRed` | **CONFIRMED** | `RecordingIcon.swift:62` — exact match |

## Phase 3 — Important findings

- **I1 (Important, contested by construction).** W11 deletes the fold y-gate; W14 adds a
  Words lane where chips are selected and ⌫-cut. That is exactly the configuration rev 4
  ruled against — `shape: gesture collision from ungated hit region`, which that ledger
  already called *"the third instance in this view."* Per Phase 5b's three-hit rule,
  patching the instance is off the table: this needs a structural guard or an explicit
  park. The spec is silent on what the cut **hit region** becomes (it specifies only the
  visual).
- **I2 (Important, CONFIRMED).** G6 — the 150pt arithmetic contradicts the shipped
  constants. W11 tells the implementer the derived minimum "follows automatically" and
  forbids hand-nudging assertions; against real constants it will not follow, and the
  tempting fix (editing `preferredAudioHeight` 44→26) is an undecided behavioural change.
  `shape: lane arithmetic on document numbers, not code constants` — **second instance**
  (pass-2 P2-3 was the first).
- **I3 (Important, CONFIRMED).** G7 — W4 is scoped as "paint plus behaviours" but its
  audio-toggle half needs a new HUD→coordinator→EDL data path that does not exist.
- **I4 (Important, CONFIRMED).** G8 — W12's single-source invariant cannot be written as
  specified without first choosing between two existing silence rules.
- **I5 (Small).** G1 — W1's migration list omits two palette tokens.

### I6 (Important, CONFIRMED by the chair inline) — the spec's mutants cannot run as written

`Scripts/mutate.sh:30-60` parses each line as **four** `::`-separated fields
(`<test-filter> :: <file> :: <find> :: <replace>`) and substitutes with Python
**literal** string replace. Its failure mode is the finding:

```
if find not in s: sys.exit(3)     →  "SKIP  anchor not found"  +  total=$((total - 1))
```

A malformed or prose mutant is **silently not counted** — the gate then reports every
mutant killed having tested nothing. Same shape as this project's known trap that
`swift test` exits 0 on a segfault. `shape: a gate whose failure mode is silence`.

Against that, essentially every mutant in rev 5 is notional, not executable:
- **Three fields, not four** — `ink0 :: srgbRed: 0.078 :: srgbRed: 0.13` parses as
  filter=`ink0`, file=`srgbRed: 0.078` → "SKIP (no such file)". This shape covers the
  large majority of the spec's ~25 proposed mutants.
- **Prose where a literal must go** — `seam draw :: (full height) :: (lane-height 18)`,
  `budget :: (fold row removed) :: (fold row kept)`, `threshold :: (shared value) :: 0`,
  `cut chip ink :: (full label colour) :: 45% opacity`, and one that says so outright:
  `capture guard :: (whatever keeps capture running) :: early return`.

**And W11 invalidates two mutants that exist and pass today** (`Tests/mutants.txt`):
```
GestureMatrixTests :: …/TimelineView.swift :: if let range = foldLaneRange, !range.contains(point.y) { return nil } ::
GestureMatrixTests :: …/TimelineView.swift :: guard let cut = foldHit(atX: point.x) else { return nil } :: guard let cut = foldHit(at: point) else { return nil }
```
The first pins **exactly the y-gate W11 deletes**. After W11 both anchors vanish, both
are silently skipped, and the gate's total quietly shrinks by two. Independent
mechanical corroboration of I1: the fold y-gate is not incidental, it is currently
mutation-covered.

**Verified aside:** W14's named axis API is real — `TimelineGeometry.x(atOutput:)`
(`TimelineGeometry.swift:207`). G-series citation quality is otherwise good.

### I1 REFINED (chair, verified inline) — the collision is per-gesture, and the spec names the wrong guard suites

`Tests/SnittAppTests/GestureMatrixTests.swift` shows the shipped fold gestures are
**already differentiated by gesture, not uniformly gated**:

| Gesture on a cut's x | Today | Test |
|---|---|---|
| Right-click → Remove Cut | works from **every** lane (ungated) | `rightClickReachesFoldsEverywhere` |
| Double-click → expand + select | works from **every** lane (ungated) | `doubleClickReachesFoldsEverywhere` |
| **Single click** | scrubs everywhere **except** the fold lane; only *in* the lane does it toggle/select | `singleClickIsGatedToTheFoldLane`, `singleClickInFoldLaneToggles` |

So the y-gate (`TimelineView.swift:541-543`, via `foldLaneRange` `:494-499`) governs
**single-click only** — and its doc says the nil-range fallback is deliberate: *"the old
full-height behaviour stands, so a cramped timeline keeps its folds reachable rather than
losing them silently."*

Consequences the spec does not address:
1. Deleting the gate gives **single click** fold-selection across the whole stack,
   where it currently means *scrub* — and, after W14, also *select a word chip*. The
   product-owner directive ("cuts aren't a lane") is about the **visual**; the spec
   silently converts it into a **gesture** change nobody decided.
2. W11 says "`GestureAxisTests` and `ExpandedFoldAxisTests` pass unmodified or the item
   is wrong." Those are not the suites at risk. **`GestureMatrixTests` is**, and two of
   its tests encode exactly the invariant W11 removes. The spec names the wrong guards,
   so an implementer following it would take a green run from suites that never covered
   the change.

`shape: directive about appearance silently reinterpreted as a change to behaviour`.

## Phase 7 — persona returns

### Principal Engineer

**PE-1 — W9's shortcut audit points at the wrong system. CONFIRMED** (chair re-verified
both hops). The spec's W9 says every claimed shortcut "resolves through
`KeyboardShortcutRegistry` (D84)". That registry holds **4 entries, all `menu: .playback`**
(`KeyboardShortcutRegistry.swift:51-59`) — editor menu key-equivalents, which require the
app to be key. The HUD's shortcuts come from a **disjoint** system: `HotkeyAction`
(`HotkeySettings.swift:12-15`) has exactly **two** cases, `.record` and `.marker`, and
`main.swift:323-332` builds the HUD's `Shortcuts` straight from `HotkeySettings.load()`.
So §2's constraint #7 ("`Shortcuts.pause` is genuinely nil today") is true for a
*structural* reason the spec never states: **no `.pause` HotkeyAction case exists.**
PE's hazard note is the valuable half — a literal reading sends the W9 implementer to
"fix" the HUD by routing it through a menu registry that needs the app to be key, which
is precisely the property §4.11 forbids the HUD to have. Triage: **Important**
(it would induce a §4.11 violation), **uncontested** — factual, no tradeoff.

**PE-2 — W5's mandated sequence test asserts a race that cannot occur. CONFIRMED**
(chair re-verified the two decisive hops). Chain: `ExportSheet.swift:94-101` — `setFormat`
is a synchronous local mutation firing no async work; `EditorWindowController.swift:1572`
— the *only* measurement fires `.onChange(of: state.exportRequestToken)`, and `:70-71`
show that token is written **only** by `requestExport()`; `ExportEstimator.menu(bundle:edl:)`
(`ExportEstimator.swift:58`) **takes no format parameter**. The estimate is computed once
per sheet-open and is format-independent — GIF merely greys the same numbers via
`estimatesApply`. There is no in-flight state for a format switch to corrupt.
PE's replacement is better than its deletion: the real race is a **stale measurement
landing on a resolution the user picked meanwhile**, and a guard for it already exists at
`EditorWindowController.swift:1581-1586` (`if exportRequest.resolution == .source`) —
currently unpinned by any test. Triage: **Important** (a mandated test that cannot fail
is worse than none — it manufactures false confidence), **uncontested**.
`shape: test specified for a race the architecture forbids`.

### Fleet-executability (Operator)

**OP-1 — mutants unrunnable. CONFIRMED, and it independently reproduces the chair's I6.**
Two sources reaching the same finding from different starting points is the strongest
evidence class in this ledger. OP adds the decisive hop the chair had not chased to its
end: the file-not-found path `continue`s **before** `total` is incremented, and the
summary is `echo "$((total - survived))/$total mutants killed."` with `exit 1` **only**
`if [ "$survived" -gt 0 ]`. So a spec of pure SKIPs prints **"0/0 mutants killed." and
exits 0** — a clean pass that ran nothing. OP also notes §7 never states the 4-field
shape nor what to do about a SKIP, so a subagent reading only its own item cannot
produce a runnable line. Triage: **Important, uncontested.**

**OP-2 — W3's isolation is invisible to the agents who must respect it. CONFIRMED.**
§7's Order bullet ("W1 first; W10 any time; W12 before or with W13; W14 after W11; W9
last… **Everything else is parallel-safe after W1**") does not name W3, while "riskiest
item, keep it alone" lives only inside W3's own brief. Under this spec's own premise —
each agent sees its item plus the global constraints — every other agent concludes W3 is
parallel-safe and has no signal W3 even exists. Triage: **Important, uncontested**;
trivially fixable. `shape: constraint stated where the party it binds cannot read it` —
kin to rev-4's `requirement written before the surface it must cover`.

### Pragmatist

**PR-1 — the mutation gate is quadratic across the fleet. CONFIRMED.**
`mutate.sh` takes one spec file and runs **every** line in it; §7 says each PR appends its
mutants to the cumulative `Tests/mutants.txt` and runs the whole file. 29 live lines today
+ ~28 from rev 5 ≈ 57 by W9, re-run on all 14 branches ≈ **620 mutant-executions instead
of ~57**, each a patch → `swift test --filter` → restore cycle against a suite whose full
pass already costs 66-88s. Triage: **Important, uncontested** (cost, not correctness).

**PR-2 — the 14-PR structure buys zero automated verification. CONFIRMED** (chair
re-verified). `.github/workflows/ci.yml:130` filters to
`SnittDocumentTests|SnittCaptureTests|SnittAutomationTests|SnittCLITests|SnittMCPTests`;
`SnittAppTests` is excluded by design (`:113` — it hangs on a headless hosted runner).
**All five guardrail suites this spec leans on live in `SnittAppTests`**: TimelinePalette,
WindowLifetime, EditorWindowGeometry, GestureAxis, GestureMatrix. So every one of the 14
PRs gets identical — zero — CI signal, even if the billing block were lifted, while
paying branch + rebase + full-local-gate + rebuild-and-eyeball overhead 14 times.
PR proposes ~5 PRs grouped by risk and file overlap.
Triage: **Important, and CONTESTED** — this is a genuine tradeoff (review granularity and
revert surface vs overhead), it collides with the chair's own stated recommendation of
one-PR-per-item, and it is the user's call, not the panel's. → cross-examination, then
the menu.

### Red team

**RT-1 — W11 does not test the regression it knowingly reintroduces. CONFIRMED.**
Third independent arrival at I1, and with the best citation: `TimelineView.swift:529-541`
says it outright — *"That was survivable while the stack was marks/video/audio… It stops
being survivable as lanes are added below Video: **an ungated full-height hit swallows
clicks meant for each of them, three times over.**"* W11's sole new test is a11y-frame ==
hit-frame, which asserts internal consistency, not cross-lane resolution; RT read
`GestureAxisTests` in full and confirms it only exercises x-axis correctness at fixed y
on 1-2-lane fixtures. RT's proposal is better than a warning: **write the cross-lane test
first** — click at a fold's x with y inside each surviving lane, assert it reaches that
lane — and *if it cannot pass without re-adding a gate, W11's shape is wrong*: the fold
needs an explicit z/priority rule, not a deletion. Triage: **Important, uncontested**
(nobody defends the deletion); the *remedy* is a design choice → menu.

**RT-2 — W14's centrepiece is already built, and the spec's threshold contradicts it.
CONFIRMED — and this is the chair's miss.** `Sources/SnittDocument/WordLaneTiers.swift`
exists, with `TranscriptPhrases.swift` for pause-bounded grouping and
`Tests/SnittDocumentTests/WordLaneTiersTests.swift` already covering it. Shipped
constants: `minimumChipWidth = 40`, `minimumPhraseWidth = 90`, `wordsPerPhrase = 8`, and
`tier()` = `perWord >= 40 → .words; perWord * 8 >= 90 → .phrases; else .density`. So the
real phrases/density boundary is **90/8 = 11.25 pt/word**, not the spec's **4**. The
words boundary (40) matches by luck. Every worked example in rev 4's table falls outside
the 4–11.25 band, so the spec's own evidence could never expose the contradiction — but a
real transcript landing in that band gets misclassified. Triage: **Important, uncontested
on the facts**; W14 shrinks from "the largest item" to a view-layer item consuming an
existing model.

`shape: spec asserts the state of code it never checked` — **third instance this pass**
(G7 RecordingCoordinator plumbing, G8 one-silence-rule, RT-2 WordLaneTiers). Per Phase 5b
the instance patch is off the table: the structural guard is a **pre-flight existence
check** — every work item must cite the symbols it claims exist or claims to create, and
be checked against the repo before dispatch. Chair's own error class, honestly logged:
`WordLaneTiers.swift` appeared in this session's very first grep output and was not
followed up.

### Product / UX

**UX-1 — the HUD mute control lies about what it does. CONFIRMED.**
`CompositionBuilder.swift:244` applies mute as `state.muted ? 0.0 : Float(state.gain)`
**inside the export/composition mix only** — never in the capture path. The spec pairs
that with live-mute iconography (`mic.slash`) and an announcement, *"Microphone will be
muted in this recording,"* fired mid-take. Someone silencing a private aside — a phone
call, a sensitive remark — will believe they succeeded while both tracks were captured to
disk in full. Triage: **Important, CONTESTED** (it collides with an explicit product-owner
request to put mic/system enable-disable on the HUD) → cross-examination.

**UX-2 — a whole-take boolean makes the natural gesture silently self-cancelling.
CONFIRMED.** `CompositionBuilder.swift:218-244` resolves **one** `TrackState` per track for
the entire mix, with no per-time-range application. So press-to-protect then
press-again-when-past — the obvious way to use a mute button — nets to **unmuted for the
whole recording**, discarding exactly the protection the user thought they had. The spec
states the hazard as if it were a virtue: *"Toggle twice → stop: unmuted — the flag is
state, not an event log."* Triage: **Important, CONTESTED**, same item as UX-1.

## Cross-examination round 1 — C1: the HUD audio toggles (contested)

All three polled personas resumed with retained context (`SendMessage`), so each judged
its own finding. Operator and Pragmatist were not polled on C1 — neither axis bears on
it; noted rather than hidden.

| Persona | Ranking | Position |
|---|---|---|
| Product/UX | **B > C > E > A > D** | B is the only option inside this rev's cost envelope that kills the mechanism of the harm — a control that *visually promises* silence that does not exist. Warns the stop-time state summary is load-bearing and needs its own test, not just a copy change. |
| Red team | **E > C > B > A > D** | Cut it: the plumbing is unbuilt, the semantics are a confirmed trap, and paying both costs at once belongs to a capability rev, not a paint rev. Substitute: **the editor gutter already ships double-click mute on `TrackState`** (`TimelineGutter.swift:26,50,102`) — same outcome, one step later, on plumbing that exists and is tested. |

**Convergence without prompting:** both rank **A last but one and D last**. A is rejected
in the strongest terms available — RT calls it *"the exact shape of a consent-relevant UI
lying about what the app just did, in an app whose W6 copy elsewhere brags about
disclosure."* Both also agree **C is more correct than B but is new scope** that does not
belong in a restyle rev. So the live question is narrowed to **B vs E**, with A and D
eliminated by agreement.

## Auto-applied (verified factual corrections; consent gate satisfied)

Each is reversible, CONFIRMED against code, touches no scope/mechanism, and carries no
live tradeoff a reasonable reviewer could settle differently.

- **A4 — lane arithmetic corrected to the shipped constants.** §4.5 and W11 now derive
  **178pt** from `TimelineLaneBudget` (`preferredAudioHeight = 44`, `transcriptLaneHeight
  = 30`), state that the rev-4 design doc's 26/26/22 are aspirational, and forbid reaching
  a smaller stack by editing those constants. Rests on G6. `shape: lane arithmetic on
  document numbers, not code constants` (2nd instance).
- **A5 — W9's shortcut audit now names both systems** and warns that routing HUD
  shortcuts through the menu registry would induce a §4.11 violation. Rests on PE-1.
- **A6 — W5's impossible test replaced** with the real unpinned race (stale measurement
  vs user-picked resolution, guard at `EditorWindowController.swift:1581-1586`).
  Rests on PE-2. `shape: test specified for a race the architecture forbids`.
- **A9 — W1's migration list completed**: `markerLane` and `audioBandMuted` named, with
  their targets flagged as an open decision rather than invented. Rests on G1.
- **A10 — W11 now names `GestureMatrixTests`** as the suite actually at risk, names the
  two tests it invalidates, and is blocked on the open hit-region decision.
  Rests on the chair's refined I1 + RT-1.

**Cross-exam round 1, Principal Engineer (cost axis — the tiebreaker).**
Ranking **B > C > A > E > D**, with the decisive costing:
- **B** = restyle/reword in `RecordingHUDPanel.swift` plus a stop-time state surface. The
  pending-per-track-bool plumbing into `RecordingCoordinator` is **not** new to B — W4
  already required it (G7), so it is shared with A, not a penalty for B. No schema or
  `CompositionBuilder` change.
- **C** = everything B needs, **plus** a `MuteSpan` type in `EditDecisionList.swift`
  (`Cut` at :36 is the precedent → `schemaVersion` 3→4, encode/decode, old-bundle
  migration), live span timestamps off the clock `Recorder.mark(label:)` uses
  (`Recorder.swift:330`), and a rewrite of `CompositionBuilder.audioMix(for:states:)`
  (`:210-257`) from one `setVolume(_, at: .zero)` per track to a piecewise envelope —
  **in the exact function whose own comments record two prior silent-corruption defects.**
  C's data shape fits the EDL fine; its *cost* is a new document capability, which §6
  forbids this rev.

**Decider's position:** A and D are eliminated by unanimous agreement (A ships a
confirmed privacy trap; D violates §4.5). C is eliminated on cost and §6 — all three
personas agree it is "more correct but new scope." That leaves **B vs E**, 2-1 for B on
first preferences, with RT calling B "the honest fallback if the product owner won't
accept E." **The Decider does NOT rule this**: the product owner explicitly requested
this control, and the skill forbids reversing a user's scope decision without asking.
→ **menu.**

## Phase 8 — blind spots

| Dimension | Disposition |
|---|---|
| Observability | Out — a UI rev's success measure is the built app compared to the design; W9's exit criterion says so honestly rather than inventing a metric. |
| Accessibility | Mostly in (contrast computed per ground, 24pt floors, a11y-frame == hit-frame in W11). **Gap: W14 never says whether word chips are accessibility elements** — rev 4 committed to "marks, folds and the playhead become real AX elements"; the words lane inherits nothing. |
| **Undo/redo** | **Gap — the spec says "undo" zero times**, yet the app has a real `UndoManager` with three registration sites (`EditorWindowController.swift:491, 533, 551`), and W11 changes what a single click *does* while W14 adds a new ⌫-cut surface. Rev 4's own ledger records a test that passed against both implementations because `UndoManager.groupsByEvent` collapses same-run-loop registrations — precisely the trap an unexamined new edit surface walks into. |
| i18n | Out — single-maintainer English-only app; the only copy work is the "Markers" audit. |
| Performance | In — §2.4 pins the 20Hz path; W12's classification reuses the existing single pass. |
| Migration / rollback | In by construction — no schema change is permitted this rev (§6), so revert is `git revert`. |
| Concurrency | Out — single-window-per-document editing; no multi-writer surface. |

## Phase 9 — adjacent initiatives

`gh pr list` returns exactly one open PR: **#89, this spec itself**. No in-flight feature
branch collides. The recently-merged branches are release-tooling fixes (#85-#88), not
editor code. **No collision, no duplication, nothing to delegate.**

## Termination — pass 3

**Condition 3: the countable box is spent** — 5 personas dispatched, 1 of 2 budgeted
cross-exam rounds used, every Important item ruled, auto-applied, or promoted to the menu.

**Verdict: PROCEED — spec materially corrected, two items rescoped, six decisions to the
product owner.** No persona argued Kill or Pivot of the rev; the Red team argued cut of
one sub-feature (the HUD toggles), which is on the menu.

**A pass 4 is deliberately deferred until after the menu is answered**, and that is the
lesson of rev 4's own pass 2: there, *every* "partially satisfied" verdict turned out to
be a NEW problem introduced by a pass-1 fix. This pass's applied changes are small text
corrections; the structural changes are the ones still on the menu. Re-running the panel
before those land would be checking the wrong artifact.

**What this loop did NOT cover:** it verified the spec's claims against the codebase; it
reviewed no implementation, because none exists. When these items produce code, that goes
to `/code-review`, not back through Phase 3.

## Decision log — pass 3 (product-owner rulings, 2026-09-10)

- **D11 — HUD audio toggles deferred until multi-point audio levels exist.** `Decided`.
  Carried by the product owner, reframing the panel's option C. Rationale: mute is the
  degenerate case of time-varying level, so the control waits for the general mechanism
  instead of inventing a `MuteSpan` one-off that would cost a `schemaVersion` bump and a
  rewrite of `CompositionBuilder.audioMix` — the function whose comments record two prior
  silent-corruption defects. *Given:* CompositionBuilder.swift:244 (export-only mute),
  :218-244 (whole-take boolean), §4.5 pristine capture, §6 no-new-capabilities.
  **Reopen trigger: gain becomes an envelope over time.** Interim answer: the gutter's
  shipped double-click mute. `shape: control whose appearance promises more than its
  mechanism delivers`.
- **D12 — W11 is gated on a cross-lane collision test, written first.** `Decided`.
  Carried by Red team, upheld by the product owner. If the test cannot pass without a
  gate, cuts need an explicit hit-*priority* rule and W11's shape is wrong — found for an
  hour's work rather than a re-litigated milestone. *Given:* TimelineView.swift:536,
  GestureMatrixTests' three-gesture split. `shape: directive about appearance silently
  reinterpreted as a change to behaviour`.
- **D13 — five PRs, not fourteen.** `Decided`. Carried by the Pragmatist. *Given:*
  ci.yml:130 excludes SnittAppTests, where all five guardrail suites live, so per-item
  PRs buy zero extra signal. Work items remain the unit of work and review; the PR is the
  unit of integration; commits stay per-item so single-item reverts survive. W3 alone.
- **D14 — W14 rescoped to the view layer; the spec adopts the shipped 11.25 boundary.**
  `Decided`. Carried by Red team. *Given:* WordLaneTiers.swift + TranscriptPhrases.swift
  + WordLaneTiersTests.swift already on main; `minimumPhraseWidth / wordsPerPhrase` =
  90/8 = 11.25, against the spec's invented 4. **Supersedes** the pass-1 word-lane
  deferral, which is now moot — the model shipped without this spec noticing.
- **D15 — the mutation gate is rewritten to four-field literal anchors; a SKIP counts as
  a failure; per-PR delta runs with one cumulative run at W9.** `Decided`. *Given:*
  mutate.sh's literal replace, its `total=$((total - 1))` on a missing anchor, and its
  `0/0 mutants killed.` + exit 0 on an all-SKIP file. `shape: a gate whose failure mode
  is silence`.
- **D16 — W12 needs no extraction; the kernel is already shared, and the invariant needs
  a named preset.** `Decided`, and it **overturns the panel's own framing**: the chair
  and three personas all treated this as "two rules, pick one." `AutoDeepTrim.swift:155-157`
  already composes `SpeechChunker.absoluteSilenceFloor` and `.referenceLevel(of:)`; the
  only difference is `DeepTrimCriteria.audioSilenceFraction`, which is **preset-dependent**
  (conservative 0.04/3.0s · default 0.08/1.5s · aggressive 0.16/0.8s) — and the default's
  0.08 *equals* `SpeechChunker.silenceFraction`. So the painter reuses the same expression
  per track and draws the **default** preset, stated on screen, because "what is drawn
  silent is what Auto-Trim cuts" is only true one preset at a time.
- **D17 — undo becomes a binding constraint (§2.7); word chips become accessibility
  elements.** `Decided`. *Given:* three `registerUndo` sites at
  EditorWindowController.swift:491/533/551 against a spec that said "undo" zero times,
  plus rev 4's `groupsByEvent` trap; and rev 4's AX-element commitment that a
  canvas-drawn lane inherits by default.

**Conformance note for the next run:** §2's list was renumbered when the undo constraint
was inserted; the one cross-reference to "constraint #7" was updated to #8. A future
walk should re-check that no other reference drifted.
