# Snitt UI Rev 5 — brand, polish, and the fleet work items

**Status:** approved design, ready to implement.
**Baseline:** rev 4 (all nine items shipped on main). Rev 5 changes character, not
structure — with two structural rulings on top: cuts stop pretending to be a lane,
and the word lane's deferral converts to a build.
**This document is normative.** Where a work item's prose and a style-sheet table
disagree, the table wins. Where this file and the HTML design doc disagree, this
file wins — it is the reviewed, committed authority.

References (visual, not normative): the rev 5 design document artifact
(`Snitt Rev 5`) and the editable canvas (`Snitt Rev 5 Screens`) — ask the product
owner for links; artifacts are private.

---

## 1. The thesis

Snitt's icon is a red record dot on deep ink — a confident, specific identity.
The app behind it is stock AppKit: `systemOrange` here, `systemRed` there,
default-blue prominent buttons, `.bar` materials everywhere. Rev 4 fixed the
structure; every layout it drew is on screen. What never shipped is the character.
Rev 5 applies one palette, drawn from the icon, to every surface.

The grammar (this is what makes it read as designed, not decorated):

- **Ink is the instrument.** Four navy-biased steps replace the neutral greys.
- **Amber is time.** Waveforms, marks, timecodes, the playhead wash, the current
  marker, the current word. If it glows amber, it is about *now*.
- **Red is recording and removal.** The record dot, the armed menu-bar item,
  cuts. Red never decorates.
- **Slate is structure.** Lane labels, rulers, hairlines, quiet text on ink.
- **Chrome stays the user's Mac.** System materials, system accent for selection
  and buttons. Snitt's character lives in the instrument, the HUD, and the
  disciplined use of amber and red — not in repainting Aqua.

## 2. Binding constraints (post-rev-4 reality)

1. **The media well follows the appearance** — white in light, black in dark
   (`EditorChromePalette.mediaWell`, product-owner reversal 2026-09-10). The
   *timeline* stays pinned dark — `TimelinePaletteTests.surfacesDoNotFollowTheAppearance`
   enforces it and stays.
2. **Expanded folds insert space into the shared timeline axis** (reflow).
   Drawing and hit-testing share ONE axis; `ExpandedFoldAxisTests` and
   `GestureAxisTests` guard it. Restyle rectangles; never add, move, or re-derive
   a position.
3. **One colour, one property.** Every token is a stored `NSColor` with a derived
   `Color` (the `currentHighlightColor` pattern — a mutant once survived because a
   test asserted `.systemOrange` by name). Tests assert against the property,
   never a re-typed literal.
4. **The transcript re-renders at 20Hz during playback.** Nothing may add
   per-tick cost to that path — no shadows, blurs, or animated modifiers on word
   views, and the words lane restyles at most the two chips changing state per tick.
5. **Sequence bugs are the house defect class** (marker revert on cache read,
   gain reset via `replaceCurrentItem`, crop with no adjustable state). Every
   interaction change names its sequence and its test asserts the sequence, not
   the final value.
6. **New windows set `isReleasedWhenClosed = false`** (`WindowLifetimeTests`
   pins the existing two; pin any new one).
7. **Every change to what an edit gesture DOES must answer for undo.** The spec's
   first draft said "undo" zero times while changing what a single click does (W11) and
   adding a new ⌫-cut surface (W14). The app has a real `UndoManager` with registration
   sites at `EditorWindowController.swift:491, 533, 551`. Two rules: a new or changed
   edit registers undo the way its neighbours do, and **`UndoManager.groupsByEvent` is on
   by default**, collapsing registrations made in one run-loop pass — rev 4 shipped a
   test that passed against both the correct and the incorrect implementation for exactly
   this reason, so a test claiming "one ⌘Z restores the whole edit" must be proven to
   fail against the version that registers twice.
8. **Colours are sRGB, never `NSColor(white:)`** (generic-gray colorspace trap,
   documented at `TimelineView.swift:1281`). The HUD renders the user's real
   shortcut bindings or nothing — never a hardcoded key that does nothing
   (PR #66's rule; `Shortcuts.pause` is genuinely nil today).

## 3. Tokens

One file owns all of these (W1). Hex for design, sRGB components for Swift,
contrast computed against the ground each token actually sits on.

| Token | Hex | sRGB components | Used for | Contrast |
|---|---|---|---|---|
| ink0 | `#14171E` | 0.078 0.090 0.118 | timeline + transport ground (was grey 0.13) | — |
| ink1 | `#1A1E27` | 0.102 0.118 0.153 | video band, HUD field (was 0.17) | — |
| ink2 | `#232834` | 0.137 0.157 0.204 | audio bands, quiet buttons on ink (was 0.22) | — |
| ink3 | `#3A4150` | 0.227 0.255 0.314 | separators, borders on ink (was 0.34) | — |
| playheadInk | `#F5F6F8` | 0.961 0.965 0.973 | playhead line + caret (was 0.97) | 16.6:1 on ink0 |
| signal | `#FF9F2E` | 1.000 0.624 0.180 | waveforms, marks, current-anything (was systemOrange) | 8.8:1 ink0 · 7.2:1 ink2 |
| signalBright | `#FFB84D` | 1.000 0.722 0.302 | hover / selected mark, play button fill | 10.4:1 on ink0 |
| clockAmber | `#FFD9A0` | 1.000 0.851 0.627 | HUD clock, transport timecode digits | 13.4:1 on ink0 |
| recordRed | `#EE4444` | 0.933 0.267 0.267 | record dot, cut fills, armed states — equals `RecordingIcon.recordRed` | 4.7:1 on ink0 |
| redBright | `#FF6B6B` | 1.000 0.420 0.420 | selected cut border, red *text* on ink | 6.5:1 on ink0 |
| slateText | `#9AA3B5` | 0.604 0.639 0.710 | lane labels, ruler, quiet text on ink | 7.1:1 ink0 · 5.8:1 ink2 |
| amberTextLight | `#9C4A00` | 0.612 0.290 0.000 | amber-meaning text on light chrome (marker timecodes) | 6.2:1 on white |
| redTextLight | `#C43D3D` | 0.769 0.239 0.239 | red-meaning text on light chrome | 5.1:1 on white |

**Red is never text on white.** `#EE4444` on white is 3.79:1 — below AA. On light
chrome it appears only as a fill or a ≥3:1 glyph; text uses `redTextLight`. Red
text on ink uses `redBright` (recordRed on ink0 is 4.7:1 — fine for the dot and
fills only).

Dynamic chrome-side variants: `amberText` resolves `amberTextLight` under .aqua
and `signal` under .darkAqua; `redText` resolves `redTextLight` / `redBright`.

## 4. The style sheet

### 4.1 Chrome surfaces — follow the appearance

The system semantic name is the source of truth; the hex is its reference
resolution for mockups and screenshot diffs.

| Surface | Source | Light ref | Dark ref | Notes |
|---|---|---|---|---|
| Editor window ground | `windowBackgroundColor` | `#ECECEC` | `#323232` | behind the rail and any chrome gap |
| Titlebar / toolbar row | `.bar` material | ≈`#F6F6F8` vib. | ≈`#3C3C3E` vib. | 1px `separatorColor` bottom edge |
| Markers rail | `windowBackgroundColor` | `#ECECEC` | `#323232` | 1px `separatorColor` trailing edge |
| Rail row, hover | quaternary fill | ≈black 5% | ≈white 8% | 120ms in / 180ms out |
| Rail row, current | signal @ 28% | `#FF9F2E` 28% | `#FF9F2E` 28% | + 2.5px signal leading bar; identical in both — a time state, not chrome |
| Media well | `EditorChromePalette.mediaWell` | `#FFFFFF` | `#000000` | pure, not near — the 2026-09-10 ruling |
| Transcript pane | `textBackgroundColor` | `#FFFFFF` | `#1E1E1E` | reading surface, not chrome grey |
| Export sheet / Settings | `windowBackgroundColor` | `#ECECEC` | `#323232` | cards inside: quaternary fill, radius 8 |
| Buttons (bordered) | system bordered style | system | system | never custom-drawn in chrome |
| Buttons (prominent) | `accentColor` | user's accent | user's accent | Export, sheet confirm, Apply — nothing else |
| Separators / hairlines | `separatorColor` | black 10% | white 10% | chrome side of the media edge included |

### 4.2 Chrome text — follow the appearance

| Role | Size / weight | Source |
|---|---|---|
| Document title (toolbar) | 13 semibold | `labelColor` |
| Document subtitle | 11 regular | `secondaryLabelColor` |
| Toolbar button labels | 13 regular | `labelColor` |
| Marker row label | 13 regular (11 when narrow) | `labelColor` |
| Marker row timecode | 11 mono medium | `SnittPalette.amberText` |
| Transcript body | 13 regular, line-height 1.5 | `labelColor` |
| Transcript cut words | 13 strikethrough, **full ink** | `labelColor` on recordRed 20% tint |
| Sheet section labels | 10 semibold, uppercase, +0.07em | `secondaryLabelColor` |
| Sheet estimate stats | 15 mono semibold, tabular | `labelColor` |
| Settings row label | 13 semibold | `labelColor` |
| Settings row explanation | 12 regular, line-height 1.5, wraps | `secondaryLabelColor` |
| Red-meaning chrome text | inherits | `SnittPalette.redText` |

### 4.3 Instrument surfaces — identical in both appearances

| Surface | Value | Notes |
|---|---|---|
| Transport bar | ink0 | 1px ink3 top border inside; chrome's `separatorColor` hairline sits above it — that pair is the whole seam treatment |
| Transport cluster | ink2 | radius 8, inner padding 3, gap 2 |
| Play/pause button | signalBright fill, ink0 glyph | 30×22, radius 5; pressed: signal |
| Transport glyph buttons | transparent; glyph slateText | 26×22; hover glyph signalBright + ink1 wash; disabled 35% |
| Timecode field | ink1, 1px ink3 border | radius 6, padding 3×8; digits clockAmber 12 mono medium; "/ total" slateText; system focus ring |
| Zoom slider + scroll bar | track ink2, thumb slateText | thumb hover playheadInk |
| Ruler strip | ink0, text slateText 9 mono | tick hairlines ink3 |
| Gutter column | ink0 | lane label 9 mono uppercase +0.08em slateText; ladder segments 2.5×5 gap 1: lit signal, hot recordRed, unlit ink3, unity tick 1px playheadInk; dB label 9 mono slateText; whole column ×0.28 when muted |
| Marks lane (24pt) | transparent on ink0 | tick 2px signal, flag glyph signal; selected/dragged signalBright; ≥24pt targets |
| Filmstrip lane (36pt) | ink1 | thumbnails inset 2, gap 1.5, radius 2 |
| Mic / System lanes (26pt each) | ink2 | active spans: signal bars; silence: 1px slateText 30% baseline; muted lane: everything ×0.28 |
| Words lane (22pt) | transparent on ink0 | chips ink2, radius 3, padding 1.5×4, text `#E8EAEF` 10 medium; current: signal 30% wash + bold; cut: recordRed 26% tint + full-ink strikethrough; pause: dashed 1px ink3 border, slateText; density strip: 6pt, ink3→signal ramp |
| Cut seam (collapsed) | recordRed, 3px full height | ruler notch 10×6 radius 2; selected: redBright + 12% full-height wash |
| Cut column (expanded) | recordRed 20% wash, redBright 2px edges | selected: 32% wash; duration chip 8 mono redBright on ink0 |
| Playhead | playheadInk, 1.5px + caret | above everything, including cuts |
| HUD field | ink1 @ 94%, border slateText 30% | radius 14; shadow 0 10 30 black 45%; clock clockAmber 12.5 mono medium; status slateText 11; quiet buttons ink2/ink3 border, glyphs playheadInk; Mark signalBright fill, ink0 label, key suffix 9.5 mono @ 75%; muted toggle slateText + slash |

### 4.4 Gradients — exactly two

The app icon's ground (`#242C40 → #10141F`, vertical) and its record dot's
specular (radial, `#FF7B6E → #EE4444 52% → #C93838`, light from 34%/28%). Every
UI surface is flat. That is a rule, not an omission: flat panels are the macOS
26+ chrome idiom, and a gradient on an instrument surface reads as decoration on
the exact surfaces whose content should carry the colour.

### 4.5 Spacing, radii, geometry

| Region | Values |
|---|---|
| Titlebar/toolbar row | height 38 · leading inset 78 (traffic lights) · h-padding 12 · control gap 10 · panel-toggle isolated by 1×16 separator + 8 gap at trailing edge |
| Transport bar | padding 12h 6v · gap 9 · cluster pad 3 gap 2 · buttons 26×22, play 30×22 · radii: cluster 8, field 6, buttons 5 |
| Timeline lanes | side padding 12 · lane gap 4 · ruler strip 14 · stack, **from the shipped constants in `TimelineLaneBudget`** (`minimumTargetHeight` 24 marks · `preferredVideoHeight` 36 · `preferredAudioHeight` **44** each · `transcriptLaneHeight` **30**) = 24+36+44+44+30 = **178pt** after the fold lane is removed. The 26/26/22 figures in the rev-4 design document are aspirational and are **not** what the code uses — never do arithmetic against them · gutter column 56 (or current width if larger) · every draggable/clickable target ≥24pt (WCAG 2.5.8) |
| Markers rail | width 260 (constant `chaptersRailWidth` — value kept) · row padding 6v 12h · current-bar 2.5 · header 11 semibold + trailing ghost "+" |
| Export sheet | width 460 · header 20h 14v · body pad 20, section gap 16 · option rows 10h 7v · stat cards pad 12, gap 10, radius 8 · footer 16h 11v |
| Settings | width 520 · content pad 20 · rows 13v, checkbox–text gap 11, checkbox top-aligned · hairline between rows |
| HUD | content insets 7/12/7/10 · gap 8 · buttons ≥28pt · divider 1×18 ink3 · radius 14 |
| Radii, globally | chrome cards/wells 8 · instrument containers 6–8 · chips 3–4 · HUD 14 · nothing else rounded |

Typography discipline: San Francisco everywhere (this is a Mac app). Every
number representing time or size is `.monospacedDigit()` or
`design: .monospaced`, no exceptions (W9 audits).

### 4.6 Motion — the complete table

Everything animated in the app. **Anything not listed here does not animate.**
All rows gate on `accessibilityDisplayShouldReduceMotion`; nothing runs on the
20Hz playback path; no springs anywhere.

| What | Property | Trigger | Duration / curve | Reduced motion |
|---|---|---|---|---|
| HUD record dot | opacity 1.0 ↔ 0.55 | while recording | 2s ease-in-out, mirrored | static, full |
| HUD idle fade | panel alpha 1.0 → 0.40 | 4s pointer-idle, recording only | 300ms ease-out; restore immediate | snap, no ramp |
| Cut band state | fill/wash colour | select, expand, collapse | 150ms ease-in-out | instant |
| Estimate refresh | stat text crossfade | measuring ↔ measured | 200ms linear | instant |
| Hover washes | background opacity | rail rows, transport glyphs, toolbar toggle | 120ms in / 180ms out, ease-out | instant |
| Transcript panel reflow | pane widths | panel toggle | 220ms ease-in-out | instant |
| Selection, playhead, drags | — | — | **never animated** | — |

## 5. Design rulings carried by this rev

- **Cuts are seams, not a lane** (product-owner direction). A cut collapses the
  *entire* timeline: `foldHit(atX:)` takes no y, and expanded folds insert space
  into the axis every lane shares. The full-height presentation (today's y-gate
  fallback) becomes the only one. The lane stack drops 178pt → 150pt.
- **The words lane ships at its honest tier** (converts rev 4's deferral). One
  pure function of points-per-word picks the tier; rev 4's measurement table is
  the binding test-case set:

  | Tier | Fires at | Draws |
  |---|---|---|
  | Words | ≥ 40 pt/word | one chip per word at its start; pauses ≥1s are dashed duration chips, selectable and cuttable. 40 = rev 4's measured chip cost (13.85 pt/word × the 2.9× zoom its table demanded) |
  | Phrases | 11.25 – 40 pt/word | one chip per pause-bounded phrase (gap ≥ 0.35s), first words + ellipsis; pauses survive every tier |
  | Density | < 11.25 pt/word | 6pt strip, words-per-second as ink3→signal ramp |

  Rev 4's rows verbatim: 0.4min/65w → 13.85 pt/word → **phrases** at 1×;
  2.5min/400w → 2.25 → **density**; 10min/1500w → 0.60 → density;
  30min/4500w → 0.20 → density.
- **HUD audio toggles are deferred until multi-point audio levels exist**
  (product-owner ruling, 2026-09-10). The capture layer records mic and system as
  separate tracks *precisely so either can be muted later* (§4.5 pristine capture;
  `TrackKind`'s doc), and no live mute exists or may be added. That leaves only an
  edit-flag control, which review confirmed is a privacy trap: it looks like it
  stopped capture when it did not, and its whole-take boolean makes the natural
  press-then-release gesture cancel itself. Mute is the degenerate case of
  time-varying level, so the control waits for the general mechanism rather than
  inventing a one-off. See W4 for the full reasoning and the reopen trigger.
- **The transcript control is a panel toggle, not an action**: icon-only
  `sidebar.trailing` at the toolbar's trailing edge past a divider, accent wash
  18% while open — the standard inspector-toggle idiom.
- **Selection stays the system accent** app-wide. Amber marks the playhead; the
  two stay different hues for every user whose accent isn't orange, and bold
  carries the playhead when they collide.
- **"Markers" everywhere** in user-facing copy (the 9f642fb rename; W9 verifies
  it held). Code identifiers like `chaptersRailWidth` may stay.
- **The icon, refined for macOS 27**: same identity, re-rendered in the Liquid
  Glass idiom — system squircle, three layers (ink ground `#242C40 → #10141F`,
  glass window pane, specular record dot), clear/tinted renditions from the
  layer structure. Geometry: window pane 15% side / 19% top-bottom margins;
  dot 31% of the side, centred; ring ≈2.3% with a 2% gap. At 16/32 the specular
  and inner shadows drop out; shape carries it. The dot is `recordRed` exactly.

## 6. Deliberately unchanged

Rev 4's layout decisions (two zones, rail collapse order, transcript as a
reflowing split), the media-well reversal, the menu-bar path (glyphs, menu,
hotkey flow — only a tint, W8), §4.11 behaviour, consent behaviour, the
three-frontend architecture, pristine capture, and the app icon's *identity*.
No new windows, no new capabilities.

---

## 7. Fleet protocol — binds every work item

- **Verification.** The gate is `./Scripts/run-tests.sh` — only its reconciled
  summary counts; a bare `swift test` exit code is untrustworthy (segfaults exit 0).
  After any visual change, rebuild the app (`./Scripts/make-app.sh`) and look at it —
  tests passing is not pixels changing, and `build/Snitt.app` is what the product owner
  runs. **Note what CI does and does not give you:** `.github/workflows/ci.yml` runs only
  `SnittDocumentTests|SnittCaptureTests|SnittAutomationTests|SnittCLITests|SnittMCPTests`
  — `SnittAppTests` is excluded by design (it hangs on a headless hosted runner), and
  *every* guardrail suite this spec leans on lives there. There is no automated signal
  for this work; the local gate and your own eyes are the whole of it.
- **The mutation gate, and how it lies.** `Scripts/mutate.sh` parses each line as
  **four** `::`-separated fields — `<test-filter> :: <file> :: <find> :: <replace>` —
  and substitutes with a **literal** Python string replace. When the anchor is not found
  it prints `SKIP` **and decrements the total**, so a file of malformed mutants reports
  `0/0 mutants killed.` and exits 0: a clean pass that tested nothing, the same failure
  shape as `swift test` exiting 0 on a segfault. Therefore:
  1. Every mutant is four real fields. The `<find>` string must be a **unique literal**
     that exists in the named file — never prose, never a parenthetical description.
     Write the code first, then anchor the mutant to what you actually wrote.
  2. **A `SKIP` counts as a FAILED mutant, not a pass.** Read the run's output, not just
     its exit status, and confirm the numerator equals the number of mutants you added.
  3. If an item deletes code another mutant anchors on, **replace that mutant in the same
     PR.** Leaving it to SKIP silently shrinks the gate.
  4. Run **only your own new lines** during the item (`Scripts/mutate.sh` accepts any
     spec file — keep a scratch file of the item's mutants). The cumulative
     `Tests/mutants.txt` is run **once, at W9**. Re-running the whole accumulated file on
     every branch costs roughly 620 mutant-executions across the series instead of ~57,
     each one a patch → filtered `swift test` → restore cycle.
  When a mutant survives, check whether the test asserts the property or something
  adjacent — this project has logged 26 adjacent-property tests.
- **Colour discipline.** Every colour comes from `SnittPalette` (W1): one
  property per token, `NSColor` stored, `Color` derived, sRGB only, no re-typed
  literals at call sites, tests assert the property. Do not delete
  `TimelinePaletteTests.surfacesDoNotFollowTheAppearance` — update its values.
- **Hands off:** the timeline geometry axis (restyle, never reposition), the
  20Hz playback path, §4.11 invariants (HUD never key/main, no window on hotkey
  start), the consent flow, the menu-bar menu's structure. Update
  `PreviewFixtures`-driven `#Preview`s alongside each surface touched — they are
  the visual regression net.
- **Branching — five PRs, not fourteen** (product-owner ruling, 2026-09-10). Since CI
  gives this work zero signal either way, one-PR-per-item buys no extra verification
  while paying branch, rebase, full-local-gate and rebuild-and-eyeball overhead fourteen
  times. The work items stay as written — they are the units of *work and review*; the
  PR is the unit of *integration*. Group them:

  | PR | Contents | Why grouped |
  |----|----------|-------------|
  | **1** | W1 | the blocking foundation; nothing else can start |
  | **2** | W2, W5, W6, W7, W8 | pure token substitution and copy, no logic change, little file overlap |
  | **3** | W11, W12, W13, W14 | all four touch `TimelineView`/the gutter; separate branches would rebase against each other continuously. **W11's step 0 gates the whole PR** |
  | **4** | W3 | the one genuine unknown (titlebar drag); isolated so a revert takes nothing else with it |
  | **5** | W9 | the sweep, after everything has landed |
  | **—** | W10 | artwork + `make-app-icon.sh` only; no `Sources/SnittApp` overlap, so it may land any time on its own branch |

  Branch from `main` per PR (`feat/rev5-pr2-recolour` …), never commit to main. Within a
  PR, commit per work item so a single item can still be reverted. Baseline at time of
  writing: 1379 tests, 29 mutant lines — both drift; trust the reconciliation, not these
  numbers.
- **Order:** PR 1 → then PR 2 and PR 4 in either order → PR 3 (its internal order is
  W11 → W12 → W13 → W14) → PR 5 last. W10 any time. **PR 4 (W3) runs alone: nothing else
  merges while it is in flight**, because the titlebar change is the one item whose
  fallback path is unknown until it is tried.

## 8. Work items

### W1 — SnittPalette: one brand, one file *(blocks all others)*

Create `Sources/SnittApp/SnittPalette.swift` holding every token from §3, then
migrate the three existing colour authorities onto it.

Shape (the `currentHighlightColor` lesson applied to every token):

```swift
enum SnittPalette {
    // The instrument — pinned, never appearance-following.
    static let ink0 = NSColor(srgbRed: 0.078, green: 0.090, blue: 0.118, alpha: 1)
    static let signal = NSColor(srgbRed: 1.000, green: 0.624, blue: 0.180, alpha: 1)
    static let recordRed = NSColor(srgbRed: 0.933, green: 0.267, blue: 0.267, alpha: 1)
    // … ink1/2/3, playheadInk, signalBright, clockAmber, redBright, slateText per §3 …
    // Chrome-side text variants are dynamic; light values from §3, dark resolves to the ink-side token.
    static let amberText = NSColor(name: "amberText") { app in
        app.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? signal
            : NSColor(srgbRed: 0.612, green: 0.290, blue: 0.000, alpha: 1)
    }
}
```

Migrations, all in this PR:

- `TimelineView.swift:1288-1300` — `Palette.background/videoBand/audioBand/separator/playhead`
  become ink0/ink1/ink2/ink3/playheadInk; `waveform` becomes `SnittPalette.signal`
  (muted keeps the 0.28-alpha derivation). **Two further tokens live in that enum and
  must not survive as neutral greys inside a navy instrument:** `markerLane = grey(0.26)`
  and `audioBandMuted = grey(0.155)`. Their ink-ramp targets are an open decision (§10) —
  do not invent values. Keep the local `Palette` enum as a
  forwarding layer so 40+ call sites don't churn.
- `FoldPalette.swift:29` — `base = NSColor.systemRed` → `SnittPalette.recordRed`;
  selected-border variant uses `redBright`. Alphas and widths (0.35/0.55, 4/2/2)
  land unchanged here — W11 retunes the geometry afterwards; do not pre-empt it.
- `EditorChromePalette.currentHighlightColor` — `.systemOrange` → the dynamic
  `amberText` pair (keep the NSColor+Color single-source shape; keep
  `currentHighlightOpacity` 0.28).
- `EditorChromePalette.timelineSurface` — the 0.13 grey → ink0, so the gutter
  matches the deck.
- `TimelinePaletteTests` — update expected component values; the
  appearance-independence assertions stay identical in intent.

Tests + mutants:

- New `SnittPaletteTests`: recordRed's components equal `RecordingIcon.recordRed`'s
  (assert the relationship, not two copies of a literal); every ink token is sRGB
  (colorSpace assertion — the `NSColor(white:)` trap); `amberText` resolves
  differently under .aqua vs .darkAqua while ink0 resolves identically.
- Mutants: `ink0 :: srgbRed: 0.078 :: srgbRed: 0.13` (old grey creeping back);
  `FoldPalette :: SnittPalette.recordRed :: NSColor.systemRed`;
  `waveform :: SnittPalette.signal :: NSColor.systemOrange`. Each must die.

### W2 — The transport joins the instrument *(after W1)*

`TransportBar` (`EditorChrome.swift`) moves from `.background(.bar)` onto ink0
and restyles for dark — closing the seam rev 4 left open. The toolbar above it
stays chrome; the `Divider().overlay(mediaEdge)` at
`EditorWindowController.swift:1504` stays as the machined edge, and the transport
adds a 1px top border in ink3.

Control treatments: per §4.3 (cluster, play, glyph buttons, timecode field,
current-mark label, cut button slateText idle / redBright enabled, zoom/scroll
dark). Replace `.borderedProminent` on play with an explicit style; keyboard
focus ring must remain visible on ink (verify with Full Keyboard Access on).
Disabled states at 35% of idle colour.

Tests + mutants:

- Extend the appearance-independence suite: the transport surface resolves
  identically under .aqua and .darkAqua.
- Mutant: `transport ground :: SnittPalette.ink0 :: NSColor.windowBackgroundColor`
  — the seam reopening must kill a test.
- Sequence check: type a time, press return, click a transport button — the
  field commits-then-acts, not acts-on-stale. Assert the order.

### W3 — Single-deck chrome: the toolbar is the titlebar *(after W1 · riskiest item, keep it alone)*

The editor window (`EditorWindowController.swift:1906`) gains
`.fullSizeContentView`; `titlebarAppearsTransparent = true`,
`titleVisibility = .hidden`. `EditorToolbar` becomes the single top row: 78pt
leading inset clearing the traffic lights, min height 38pt; its title/subtitle
stack becomes the window's visible identity.

Sequence & risks — read before coding:

- Window dragging: with a transparent titlebar the top strip must still drag the
  window. Verify by hand in `build/Snitt.app`; if the SwiftUI row swallows the
  drag, the documented fallback is a titlebar-accessory arrangement — never a
  reimplemented drag.
- Do not disturb: `isReleasedWhenClosed = false`; the geometry statics
  (`openingContentRect`, `minimumContentSize` — their tests pass untouched); and
  `editorChromeHeight` — if the chrome row's height changes, that constant and
  `EditorWindowGeometryTests.minimumContentSizeIsDerived` follow *by derivation,
  not by nudging the assertion*.
- The window's real `title` still gets set (Mission Control, Window menu,
  VoiceOver read it) — hidden is not empty. Assert both:
  `titleVisibility == .hidden` and `title` non-empty.
- **The transcript control becomes a panel toggle** in this PR (toolbar layout):
  the labelled "Transcript" toggle is replaced by an icon-only toggle
  (`sidebar.trailing`) at the trailing edge past a 1×16 divider, after Export.
  Accent wash 18% while open; `.help("Show the transcript panel")`; rendered only
  when `hasTranscript`; shortcut unchanged through the D84 registry. Test: the
  toggle's accessibility role/label says it shows a panel, not that it performs
  an action.

Mutant: `titleVisibility = .hidden :: .visible` — kill with the visibility
assertion, and eyeball the double-title regression in the built app.

### W4 — The HUD in ink *(after W1)*

`RecordingHUDPanel.swift` — paint plus two behaviours. Never-key /
non-activating invariants and their tests are untouchable.

Paint: per §4.3's HUD row. Dot recordRed (was systemRed); paused keeps the
hollow-ring shape grammar. Mark becomes the emphasised control: signalBright
fill, ink0 glyph/label, its shortcut *visible* as a small monospaced suffix
("⚑ Mark ⌥⌘M") rendered from the user's real binding via `Shortcuts`; no
binding → no suffix. Pause/stop: ink2 fill, ink3 border, playheadInk glyphs;
paused-state resume keeps `record.circle.fill`, tinted recordRed. All buttons
≥28pt.

Behaviours (each is a sequence — test the order):

- **Dot breathe**: 2s opacity 1.0→0.55, only while recording. Paused or
  reduced-motion → static full. Factor the decision into a pure
  `RecordingHUDModel` function `(state, reduceMotion) → animates: Bool`; test
  the four combinations there — don't unit-test CoreAnimation.
- **Idle fade**: `NSTrackingArea` on the content; 4s after the pointer leaves
  (recording only, never paused), animate `alphaValue` to 0.40 over 300ms;
  pointer-enter restores 1.0 immediately. Model the decision purely:
  `(state, pointerNear, secondsIdle) → alpha`. Sequence test: pause *during* the
  fade → alpha restores (a paused HUD is reporting an abnormal state and must be
  fully visible).
- **Audio source toggles — DEFERRED, do not build in this rev.** An earlier draft
  put mic and system-audio toggles on the HUD. Review killed that design, and the
  product owner's ruling is to **wait for multi-point audio levels** (2026-09-10).
  The reasoning, recorded so this is not re-litigated from scratch: mute applies
  **only in the export mix** (`CompositionBuilder.swift:244`,
  `state.muted ? 0.0 : Float(state.gain)`) — capture never stops and both tracks
  always reach disk — so a live control wearing `mic.slash` and announcing
  "Microphone will be muted in this recording" tells a user their private aside was
  protected when it was captured in full. And `TrackState` is **one boolean for the
  whole take** (`CompositionBuilder.swift:218-244` resolves one state per track with
  no time ranges), so pressing it twice to cover a moment nets out to unmuted for the
  entire recording — discarding exactly the protection the user believed they had.
  A real live mute is forbidden by §4.5 pristine capture, so the honest version needs
  **time-varying audio state**, of which mute is the degenerate case. **Reopen when
  multi-point audio levels land** — gain as an envelope over time rather than one
  scalar per track. At that point the HUD control becomes a natural producer of level
  points, no new document concept is invented for it alone, and the "press to protect,
  press again to release" gesture means what it looks like. Until then the editor
  gutter's double-click mute (`TimelineGutter.swift:26`) is the shipped answer: same
  outcome, one step later, on plumbing that already exists and is already tested.

Mutants (four-field, literal anchors — see §7):
```
RecordingHUDPanelTests :: Sources/SnittApp/RecordingHUDPanel.swift :: <the recordRed dot assignment, verbatim> :: NSColor.systemRed.cgColor
RecordingHUDModelTests :: Sources/SnittApp/RecordingHUDModel.swift :: <the idle-fade alpha constant, verbatim> :: 1.0
RecordingHUDModelTests :: Sources/SnittApp/RecordingHUDModel.swift :: <the breathe guard condition, verbatim> :: !isPaused
```
Anchor each `<…>` to the exact unique literal you wrote, and confirm the run reports
them **killed**, never `SKIP`.

### W5 — Export sheet, promoted *(after W1 · small)*

`ExportSheet.swift` — structure, wording, fallback copy, and greyed-not-hidden
GIF ceilings all stay. Changes:

- The two estimate figures become the visual centre: a two-stat row above the
  footer (size ceiling · export time), `.title3` monospaced semibold on a
  `.quaternary` card. 200ms crossfade measuring↔measured; `.monospacedDigit()`
  so re-measures don't jitter.
- Resolution rows: real radio affordances ≥16pt; selected row washed with the
  system accent at 9%.
- Header gains the format glyph leading the title; Export stays
  `.borderedProminent` system accent.
- Sequence test: **the race an earlier draft specified (switching format while
  measuring) cannot occur.** `setFormat` is a synchronous local mutation;
  `ExportEstimator.menu(bundle:edl:scale:)` takes no format parameter; the only
  measurement fires on `state.exportRequestToken`, whose sole writer is `requestExport()`.
  The estimate is computed once per sheet-open and is format-independent — GIF only greys
  the same numbers. A mandated test that cannot fail manufactures false confidence, so it
  is replaced by the real, currently unpinned race: **a stale measurement landing on a
  resolution the user picked in the meantime.** The guard already exists at
  `EditorWindowController.swift:1581-1586` (`if exportRequest.resolution == .source`) and
  no test covers it. Pin it, through the existing token/provider seam, not sleeps.
- Mutants: `estimatesApply :: format == "mp4" :: true` (existing, must still
  die) plus `measuring guard :: isMeasuring :: false` against the crossfade
  guard the implementation introduces.

### W6 — Settings rows that explain themselves *(after W1 · independent)*

`SettingsWindowController.swift:229-260ff` — window grows to 520×auto; each
checkbox becomes a row: checkbox top-aligned, bold 13pt label, wrapping 12pt
secondary explanation, hairline between rows. The four explanations, **verbatim
— copy, don't rewrite**:

1. *Allow agent recording* — "Lets Claude Code or Codex start a recording
   without you at the keyboard. Every agent-initiated recording is disclosed in
   the UI and logged."
2. *Log input events* — "Records which keys and clicks happened, so auto-trim
   can tell working from idle. Keystrokes are stored as content-free beats —
   never the characters."
3. *Record voiceover* — "Captures the microphone alongside system audio. Snitt
   warns you if your speakers will bleed into the mic."
4. *Include crash reports in diagnostics* — "Attaches recent crash logs when you
   export a diagnostics bundle. Nothing is sent anywhere — the bundle is a file
   you choose to share."

Hotkey and save-location rows keep their controls with the same label treatment.
All toggle plumbing (the `EventLoggingToggle.apply` ladder, microphone rung,
conflict alerts) is untouched and its tests pass unmodified.
`isReleasedWhenClosed = false` stays pinned by `WindowLifetimeTests`.

Tests: each row exposes label AND explanation to accessibility (subtitle in
`accessibilityHelp` or an associated static text — assert it); window width
≥520. Mutant: `agent-recording explanation :: "disclosed in the UI and logged" :: ""`
— pin the consent-relevant sentence specifically.

### W7 — Rail and transcript: time reads amber *(after W1 · small)*

- `MarkerPane.swift`: marker timecodes → `SnittPalette.amberText`, monospaced;
  the current row's wash flows from `currentHighlightColor` and follows W1
  automatically — verify, don't re-implement. Row hover: `.quaternary` wash +
  pointing cursor.
- `TranscriptPane.swift`: playhead word wash follows W1's token (verify).
  Selection stays `Color.accentColor`. Cut words keep full-ink strikethrough on
  tint. **No new modifiers on word views** — 20Hz path; hover effects out of
  scope here.
- Confirm the transport current-mark flag glyph picks up signal from W1.
- Test: timecode colour asserts against `SnittPalette.amberText` the property.
  Mutant: `timecode :: SnittPalette.amberText :: NSColor.secondaryLabelColor`.

### W8 — The menu bar knows it's recording *(after W1 · smallest)*

`StatusItemController.swift` — add `tint: NSColor?` to `StatusItemPresentation`
(line 55): recording → recordRed, paused → signal, idle/stopping → nil
(template). Apply via `button.contentTintColor` beside the symbol assignment at
line 336. State→presentation is a pure tested mapping — extend those tests with
the tint column; the glyph grammar is untouched, so colour is additive, never
the only channel.

Mutants: `recording tint :: SnittPalette.recordRed :: nil` and
`paused tint :: SnittPalette.signal :: SnittPalette.recordRed`.

### W10 — The icon, rebuilt in layers *(no code dependency — start any time)*

Re-render per §5's icon ruling. Deliverables & pipeline:

- Layered sources in `Resources/icon/` — one vector per layer, plus the geometry
  constants recorded in a README so the next re-render isn't eyeballed.
- An Icon Composer `.icon` document for the macOS 26+ Liquid Glass treatment.
  **Named risk:** the build is SwiftPM + `make-app.sh`, not Xcode — compiling a
  `.icon` into the bundle needs verification. If it doesn't fit, ship the flat
  rendition now and check the `.icon` source in beside it.
- Regenerate `Resources/AppIcon.png` → `AppIcon.icns` through
  `Scripts/make-app-icon.sh`, keeping its per-size philosophy (full glass at
  128+, specular/inner shadows dropped at 16/32).
- The dot's fill is `recordRed`'s exact components; `RecordingIcon`'s equality
  relationship must still hold. If the artwork's red ever moves, the constant
  and W1's palette move with it, in the same PR.

### W11 — Cuts are seams, not a lane *(after W1 · touches drawing only, never the axis)*

Remove the y-gated fold lane from `TimelineView`; the full-height presentation
(today's short-view fallback) becomes the only one, styled per §4.3. Every
x-coordinate continues to come from the shared axis — restyle rectangles, never
add, move, or re-derive a position. `GestureAxisTests` and
`ExpandedFoldAxisTests` pass unmodified or the item is wrong. **Those are not the suites
at risk, though:** `Tests/SnittAppTests/GestureMatrixTests.swift` encodes the fold lane's
gesture semantics, and two of its tests — `singleClickIsGatedToTheFoldLane` and
`singleClickInFoldLaneToggles` — assert exactly the invariant this item removes. A green
run from the axis suites proves nothing about this change.

**Step 0 — write the collision test BEFORE any other change, and let it decide the
item's shape.** This is a hard gate (product-owner ruling, 2026-09-10). The directive
"cuts don't belong in their own lane" is about the **drawing**; deleting the y-gate
silently converts it into a **gesture** change, because today right-click and
double-click already reach a cut from every lane and only *single click* is gated —
elsewhere single click means scrub, and after W14 it also means select a word chip.
`TimelineView.swift:536` states the hazard outright: *"an ungated full-height hit
swallows clicks meant for each of them, three times over."*

The test: click at a cut's x with y inside **each** surviving lane (Marks, Filmstrip,
Mic, System, Words) and assert the click resolves to **that lane's** own gesture, not
`foldHit`. Write it, watch it fail against the ungated implementation, then make it pass.

**If it cannot be made to pass without re-introducing some form of gate, this item's
shape is wrong** — cuts then need an explicit hit *priority* rule (single click yields
to the lane under the pointer; right-click and double-click keep reaching the cut from
anywhere, as they already do), not a deletion. Discovering that costs an hour here and a
re-litigated milestone later. Report which way it went before continuing.

Steps (after step 0):

- Delete the fold-lane branch and its y-gate; `foldHit(atX:)` is untouched.
  Collapsed cut: 3px seam, recordRed, ruler notch; selected adds 12% wash +
  redBright. Expanded: full-stack column, recordRed 0.20 wash / redBright 2px
  edges (0.32 selected); duration chip at the ruler, 8pt mono redBright.
  `FoldPalette`'s four-appearance structure absorbs the retuned values — it
  stays the single authority.
- Draw order: seams and columns above lane content, below the playhead.
- **Undo (§2.7):** whatever step 0 settles, if single click gains a new *edit* meaning
  anywhere, that edit registers undo like its neighbours; selection alone does not.
- `TimelineLaneBudget`: remove the fold lane's 24pt + gap; update the derived
  arithmetic and its tests *by derivation* (stack becomes **178pt** — `naturalHeight`
  minus `foldLaneHeight`. The 150pt figure in an earlier draft was arithmetic on the
  design document's aspirational lane heights, not on the shipped `preferredAudioHeight
  = 44` / `transcriptLaneHeight = 30`. **Reaching a smaller stack by editing those two
  constants is a behavioural change nobody has decided — not part of this item**;
  `minimumContentSizeIsDerived` follows automatically — if any assertion needs
  hand-nudging, the derivation is broken; stop and fix that).
- Accessibility: fold elements in `TimelineAccessibility` keep their roles; only
  their frames grow to full height — which must equal the hit region
  `foldHit(atX:)` claims. New test: a11y frame == hit frame, per fold, both
  states.

Mutants (four-field, literal anchors — see §7). Two existing entries in
`Tests/mutants.txt` anchor on the code this item deletes and **must be replaced in the
same PR, not left to SKIP**:
```
GestureMatrixTests :: Sources/SnittApp/TimelineView.swift :: if let range = foldLaneRange, !range.contains(point.y) { return nil } ::
GestureMatrixTests :: Sources/SnittApp/TimelineView.swift :: guard let cut = foldHit(atX: point.x) else { return nil } :: guard let cut = foldHit(at: point) else { return nil }
```
Their replacements must pin whatever step 0 settles — the priority rule if one is added,
or the new cross-lane contract if not — plus the selected-wash alpha and the lane-budget
row, each anchored to the exact literal you wrote.

### W12 — The segmented waveform *(after W1 · before or with W13)*

The waveform painter in `TimelineView` draws classified spans: activity as bar
clusters (signal; ×0.28 muted), silence as a 1px slateText 30% baseline.

The classification is the whole item:

- **There is nothing to extract — the shared kernel already exists.** An earlier draft
  said "extract auto-trim's silence rule" as though one monolithic rule existed; review
  found that `AutoDeepTrim.swift:155-157` already builds its per-track threshold out of
  `SpeechChunker`'s primitives:
  ```swift
  max(SpeechChunker.absoluteSilenceFloor,
      SpeechChunker.referenceLevel(of: track.peaks) * criteria.audioSilenceFraction)
  ```
  The painter uses **that same expression, per track** — same primitives, one threshold
  per lane against that lane's own reference level (a mic and a system tap sit at
  different levels, which is why the shipped code is per-track and the lane must be too).
  **Write no new threshold and no new constant.**
- **The invariant needs a named preset, because the parameters are preset-dependent.**
  `DeepTrimCriteria` varies both numbers: conservative `0.04` / 3.0s minimum span,
  default `0.08` / 1.5s, aggressive `0.16` / 0.8s. So "a span the painter draws silent is
  a span Auto-Trim would cut" is **only true for one preset at a time**. The lane draws
  the **default** preset (whose `0.08` is also `SpeechChunker.silenceFraction`, so the two
  agree exactly there), and the minimum-span hysteresis comes from the same preset rather
  than an invented value. Say so where a user can see it: running Aggressive cuts more
  than the lane showed, and that is honest only if stated. The test asserts the invariant
  **against the default preset**, on a fixture with a known silent middle.
- Segment caps 1px rounded; spans shorter than the preset's minimum span merge into
  their neighbour (hysteresis from `DeepTrimCriteria`, not an invented per-pixel rule),
  and sub-2px spans collapse visually. Same single pass over the peak columns as today.
- `PreviewFixtures`' LCG peaks gain a deliberate silent middle third so every
  preview shows bars, baseline, bars.

Tests + mutants: segmentation is pure — test on arrays, not pixels (known-silent middle
→ one merged silent span; all-quiet → entirely baseline; all-hot → one span), plus the
cross-check that the painter's spans match `AutoDeepTrim`'s at the default preset.
Mutants (four-field, literal anchors — see §7):
```
WaveformSegmentationTests :: Sources/SnittApp/TimelineView.swift :: <the threshold expression, verbatim> :: 0
WaveformSegmentationTests :: Sources/SnittApp/TimelineView.swift :: <the minimum-span merge guard, verbatim> :: 0
```

### W13 — The gain ladders, branded and on deck *(after W1 · small)*

`GainMeter`'s arithmetic (12 × 3dB, unity at segment 8, hot at-or-above unity)
is correct, tested, untouched. Paint and placement for its view in
`TimelineGutter`:

- Lit segments signal; hot segments recordRed (`isHot(segment:)` decides, the
  view only colours); unlit ink3 on ink0. Unity gets a 1px playheadInk tick.
  Muted track: whole ladder ×0.28. dB label (`label(forGain:)`, incl. "−∞")
  slateText mono 9pt.
- Drag-to-set and the playhead-preserving gain path (D88) untouched — re-run
  that sequence test.
- Update the four-state `GainMeterView` previews.

Mutants: `hot :: SnittPalette.recordRed :: SnittPalette.signal` ·
`muted ladder :: 0.28 :: 1.0`. Assert against palette properties.

### W14 — The words lane, at its honest tier *(after W1 and W11 · view layer only)*

**The model already exists — do not rebuild it.** An earlier draft called this "the
largest item" and specified building a pure tier function. Review found
`Sources/SnittDocument/WordLaneTiers.swift` already on `main`, with
`TranscriptPhrases.swift` for pause-bounded grouping and
`Tests/SnittDocumentTests/WordLaneTiersTests.swift` already covering it — including
monotonicity. This item is therefore **view-layer only**: draw a 22pt lane below System
that renders whatever tier `WordLaneTiers.tier(wordCount:laneWidth:)` returns.

Structure:

- **Consume `WordLaneTiers`; add no second tier function under any name.** Its shipped
  constants are `minimumChipWidth = 40`, `minimumPhraseWidth = 90`,
  `wordsPerPhrase = 8`, so the real boundaries are **≥40 pt/word → words** and
  **90 ÷ 8 = 11.25 pt/word → phrases**, below which density. §5's table states these.
  An earlier draft said the phrases/density boundary was **4 pt/word**, a number nothing
  in the codebase produces; every worked example in rev 4's table happens to fall outside
  the 4–11.25 band, which is why the contradiction was invisible in the spec's own
  evidence and would have surfaced only as a misclassified real transcript.
  `WordLaneTiers.zoomNeeded` already reports how far to zoom to reach a target tier —
  use it rather than recomputing. Zoom feeds the *lane width*; no stored mode, no
  setting.
- Every chip's x comes from the shared axis (`x(atOutput:)` of the word's
  start) — the lane survives expanded-fold reflow for free; a test asserts a
  word after an expanded cut sits at the axis's answer. **No second time→x
  mapping, under any name.**
- Phrase grouping comes from `TranscriptPhrases`, not from a new rule here; pauses
  ≥ 1s render as dashed duration chips in every chip tier. Density: 6pt strip, words-per-second
  bucketed per pixel column, ink3→signal ramp.
- States reuse existing single sources: current word from
  `currentHighlightColor` + bold; cut words full-ink strikethrough on recordRed
  26% tint (assert full ink — rev 4's contrast finding is a test, not a
  preference); selection `accentColor`. Select-then-⌫ routes through the same
  cut path the transcript pane uses (D62) — one gesture, one implementation.
- **Perf:** the 20Hz current-word tick restyles at most the two chips changing
  state. Lane layout is a function of (transcript, axis, tier) and caches until
  one changes; the playhead tick is not one of them.
- Collapse order unchanged: Words still hides first under height pressure, and
  the Show All Lanes escape hatch lists it.
- **Accessibility: the chips are elements, not pixels.** Rev 4 committed to marks, folds
  and the playhead becoming real accessibility elements so VoiceOver's rotor can step
  between them; a canvas-drawn word lane inherits none of that by default. In the chip
  tiers each chip is an element carrying its word and its time; in the density tier the
  lane is one element describing where speech is, not thousands of unreachable buckets.
  Selection and the ⌫ cut are reachable from the keyboard, matching the transcript pane's
  existing gesture rather than inventing a second one.
- **Undo (§2.7):** the chip ⌫ cut registers undo exactly as the transcript pane's cut
  does — same path, one registration, and a test proven to fail against a double
  registration.

Tests + mutants. The tier arithmetic is **already tested** in
`WordLaneTiersTests` — do not duplicate it. What is untested is the **view**: that the
lane renders the tier the model returns, that a chip after an expanded cut sits at the
axis's x, and that cut words draw at **full ink** with strikethrough rather than reduced
opacity (rev 4's accessibility finding, which is a test, not a preference).
Mutants (four-field, literal anchors — see §7):
```
WordLaneViewTests :: Sources/SnittApp/TimelineView.swift :: <the tier switch's .words case, verbatim> :: case .phrases
WordLaneViewTests :: Sources/SnittApp/TimelineView.swift :: <the cut-chip label colour, verbatim> :: .withAlphaComponent(0.45)
```

### W9 — The polish sweep *(last — after all others merge)*

One pass, one PR, a checklist not a design:

- **Tabular time everywhere**: every view rendering a timestamp, duration, or
  byte size carries `.monospacedDigit()` or monospaced design — grep the
  renderers across `Sources/SnittApp`; fix stragglers.
- **Lane labels**: 9pt monospaced uppercase +0.08em slateText in the lane
  painter (the one piece W2 didn't own).
- **Cursors**: pointing hand on marker rows and word chips; verify resize
  cursors on dividers; open-hand while dragging markers only if it doesn't touch
  axis code.
- **Focus**: with Full Keyboard Access on, walk toolbar → transport → timeline
  → rail; every stop visibly ringed on its actual ground (ink surfaces are the
  ones likely to swallow the ring).
- **Help audit**: every control has `.help`, and every claimed shortcut resolves through
  the system that actually owns it. **These are two disjoint systems, and conflating them
  is dangerous:** editor and menu shortcuts resolve through `KeyboardShortcutRegistry`
  (D84) — four entries, all `menu: .playback`, which require the app to be key. The HUD's
  global recording shortcuts resolve through `HotkeySettings`/`HotkeyAction`, which has
  exactly two cases, `.record` and `.marker`; `main.swift:323-332` builds the HUD's
  `Shortcuts` straight from `HotkeySettings.load()`. **Pause names no shortcut because no
  `.pause` `HotkeyAction` exists** — the structural reason behind §2's constraint #8. Do
  **not** route HUD shortcuts through the menu registry: it requires the app to be key,
  which is exactly what §4.11 forbids the HUD to be.
- **Copy audit — "Markers" everywhere**: no user-facing string says "chapter"
  (verify the 9f642fb rename held, incl. menus, help strings, user-visible
  export metadata labels). Identifiers like `chaptersRailWidth` may stay.
- Update all `#Preview` blocks and `PreviewFixtures` to final tokens; screenshot
  each preview surface against the design canvas — the fixture is the visual
  contract.

Exit criterion: the built app, screen by screen, against the design — chrome
follows the system, the instrument holds ink, amber means now, red means
recording or removal, and no surface renders a system default the brand
replaced.

---

## 9. Still open, still honest

- **HUD audio toggles** — deferred with a named trigger: **multi-point audio levels**.
  When gain becomes an envelope over time rather than one scalar per track, the HUD
  control becomes a natural producer of level points and the press-to-protect gesture
  means what it looks like. Do not rebuild the one-off before then (W4).
- **Whether the timeline ever follows the appearance** — deliberately deferred
  until the branded ink deck has lived inside a light window.
- **The words lane at real scale** — `WordLaneTiers` is built and tested, but its
  density ramp and phrase grouping have never been *seen* against a ten-minute narrated
  transcript. W14 draws them; the first long recording judges them.
- **W11's step 0 may reshape W11.** If the cross-lane collision test cannot pass without
  a gate, cuts need an explicit hit-priority rule rather than a deletion — a bigger change
  than this item is scoped for, and one to bring back rather than improvise.
- **W3's drag behaviour** — the one genuine unknown; fenced as its own PR with a
  named fallback.
- **Whether a `.icon` document can enter the SwiftPM + `make-app.sh` bundle**
  without Xcode — W10 ships the flat rendition either way.
- **Live level ballistics** — the gain ladder shows the level you *set*, not the
  level playing. A live playback meter would ride the 20Hz-protected path;
  deliberately not in this set.
