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
