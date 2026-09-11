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
7. **Colours are sRGB, never `NSColor(white:)`** (generic-gray colorspace trap,
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
| Timeline lanes | side padding 12 · lane gap 4 · ruler strip 14 · stack 24+36+26+26+22 + 4×4 = **150pt** · gutter column 56 (or current width if larger) · every draggable/clickable target ≥24pt (WCAG 2.5.8) |
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
  | Phrases | 4 – 40 pt/word | one chip per pause-bounded phrase (gap ≥ 0.35s), first words + ellipsis; pauses survive every tier |
  | Density | < 4 pt/word | 6pt strip, words-per-second as ink3→signal ramp |

  Rev 4's rows verbatim: 0.4min/65w → 13.85 pt/word → **phrases** at 1×;
  2.5min/400w → 2.25 → **density**; 10min/1500w → 0.60 → density;
  30min/4500w → 0.20 → density.
- **The HUD's audio toggles are edit decisions, not capture switches.** The
  capture layer records mic and system as separate tracks *precisely so either
  can be muted later* (§4.5 pristine capture; `TrackKind`'s doc). No live mute
  exists and none may be added. The toggle writes the take's initial
  `TrackState.muted`; both tracks always capture; the gutter reverses it.
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
  summary counts; a bare `swift test` exit code is untrustworthy (segfaults exit
  0). Add each item's mutants to `Tests/mutants.txt` and run
  `./Scripts/mutate.sh Tests/mutants.txt`; every mutant must die. When one
  survives, check whether the test asserts the property or something adjacent —
  this project has logged 26 adjacent-property tests. After any visual change,
  rebuild the app (`./Scripts/make-app.sh`) and look at it — tests passing is
  not pixels changing, and `build/Snitt.app` is what the product owner runs.
- **Colour discipline.** Every colour comes from `SnittPalette` (W1): one
  property per token, `NSColor` stored, `Color` derived, sRGB only, no re-typed
  literals at call sites, tests assert the property. Do not delete
  `TimelinePaletteTests.surfacesDoNotFollowTheAppearance` — update its values.
- **Hands off:** the timeline geometry axis (restyle, never reposition), the
  20Hz playback path, §4.11 invariants (HUD never key/main, no window on hotkey
  start), the consent flow, the menu-bar menu's structure. Update
  `PreviewFixtures`-driven `#Preview`s alongside each surface touched — they are
  the visual regression net.
- **Branching:** branch from `main` per item (`feat/rev5-w1-palette` …), one PR
  per item, never commit to main. Baseline at time of writing: 1379 tests, 28
  mutants — both drift; trust the reconciliation, not these numbers.
- **Order:** W1 first; W10 any time (artwork only); W12 before or with W13;
  W14 after W11; W9 last, after all others merge. Everything else is
  parallel-safe after W1 but merges sequentially — expect rebases in
  `Sources/SnittApp`.

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
  (muted keeps the 0.28-alpha derivation). Keep the local `Palette` enum as a
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

`RecordingHUDPanel.swift` — paint plus three behaviours. Never-key /
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
- **Audio source toggles** (new controls): two buttons after a 1px ink3 divider —
  mic (`mic`/`mic.slash`) and system audio (`speaker.wave.2`/`speaker.slash`).
  Active = playheadInk on ink2; muted = slateText with the slash carrying the
  shape. ≥28pt targets. Semantics per §5: the toggle writes the take's initial
  `TrackState.muted`; capture untouched. Plumb through `RecordingCoordinator`'s
  pending state. A source not being captured at all (mic off in Settings)
  renders disabled, not muted — different facts. Each flip posts an
  accessibility announcement ("Microphone will be muted in this recording").
  Sequence tests: toggle mic → pause → resume → stop: bundle's track state
  muted AND both audio files exist with real duration (pristine capture
  asserted). Toggle twice → stop: unmuted — the flag is state, not an event log.

Mutants: `dot :: SnittPalette.recordRed :: NSColor.systemRed` ·
`fade :: 0.40 :: 1.0` · `breathe guard :: isPaused :: !isPaused` ·
`mic toggle :: TrackState.muted = true :: false` · a capture-guard mutant killed
by the both-files-exist assertion.

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
- Sequence test: change format MP4→GIF *while measuring* — the in-flight
  estimate must not land on the GIF state (assert via the existing
  token/provider seam, not sleeps).
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
`ExpandedFoldAxisTests` pass unmodified or the item is wrong.

Steps:

- Delete the fold-lane branch and its y-gate; `foldHit(atX:)` is untouched.
  Collapsed cut: 3px seam, recordRed, ruler notch; selected adds 12% wash +
  redBright. Expanded: full-stack column, recordRed 0.20 wash / redBright 2px
  edges (0.32 selected); duration chip at the ruler, 8pt mono redBright.
  `FoldPalette`'s four-appearance structure absorbs the retuned values — it
  stays the single authority.
- Draw order: seams and columns above lane content, below the playhead.
- `TimelineLaneBudget`: remove the fold lane's 24pt + gap; update the derived
  arithmetic and its tests *by derivation* (stack becomes 150pt;
  `minimumContentSizeIsDerived` follows automatically — if any assertion needs
  hand-nudging, the derivation is broken; stop and fix that).
- Accessibility: fold elements in `TimelineAccessibility` keep their roles; only
  their frames grow to full height — which must equal the hit region
  `foldHit(atX:)` claims. New test: a11y frame == hit frame, per fold, both
  states.

Mutants: `selected wash :: 0.32 :: 0.20` · `seam draw :: (full height) ::
(lane-height 18)` (killed by the frame-equality test) · `budget :: (fold row
removed) :: (fold row kept)` against the derived-minimum test.

### W12 — The segmented waveform *(after W1 · before or with W13)*

The waveform painter in `TimelineView` draws classified spans: activity as bar
clusters (signal; ×0.28 muted), silence as a 1px slateText 30% baseline.

The classification is the whole item:

- **One silence rule, two consumers.** Auto-trim already classifies
  idle-vs-working spans. Extract its audio-silence decision into one shared pure
  function (threshold + minimum-span hysteresis) consumed by both the trim
  pipeline and the painter — never a second threshold in the view. If the
  existing classifier blends audio with input-event evidence, extract only the
  audio term and document the seam. Invariant, with a test: a span the painter
  draws as silent is a span Auto-Trim would treat as silent, on a fixture with a
  known silent middle.
- Segment caps 1px rounded; spans shorter than 2px merge into their neighbour
  (hysteresis, not per-pixel flicker). Same single pass over the peak columns as
  today.
- `PreviewFixtures`' LCG peaks gain a deliberate silent middle third so every
  preview shows bars, baseline, bars.

Tests + mutants: segmentation is pure — test on arrays, not pixels
(known-silent middle → one merged silent span; all-quiet → entirely baseline;
all-hot → one span). Mutants: `threshold :: (shared value) :: 0` (the solid
waveform sneaking back) · `hysteresis :: minSpan :: 0` ·
`painter :: silent → baseline :: silent → bars`.

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

### W14 — The words lane, at its honest tier *(after W1 and W11 · the largest item)*

Build the words lane per §5's tier table: a 22pt lane below System drawing
whichever tier the arithmetic earns. Rev 4's deferral ruling — "prototype the
zoom transitions against a real transcript" — is satisfied by the tier model:
there is no wrong zoom because the tier follows the zoom.

Structure:

- The tier decision is one pure function
  `(laneWidthPoints, wordCount) → .words | .phrases | .density`, thresholds 40
  and 4 pt/word (40 is rev 4's measured chip cost, not a taste call). Zoom feeds
  it the zoomed width — no stored mode, no setting.
- Every chip's x comes from the shared axis (`x(atOutput:)` of the word's
  start) — the lane survives expanded-fold reflow for free; a test asserts a
  word after an expanded cut sits at the axis's answer. **No second time→x
  mapping, under any name.**
- Phrase grouping: pause-bounded (gap ≥ 0.35s); pauses ≥ 1s render as dashed
  duration chips in every chip tier. Density: 6pt strip, words-per-second
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

Tests + mutants: tier function against rev 4's table verbatim (the 2.5-min row
yields .density — 2.25 sits under 4, exactly the boundary a test exists for; the
0.4-min row yields .phrases at 1× and .words at 3×). Boundaries at 40.0 and 4.0
exactly. Mutants: `tier :: 40 :: 0` (everything word chips — the lie rev 4
refused to ship) · `phrase gap :: 0.35 :: 0` ·
`cut chip ink :: (full label colour) :: 45% opacity` (re-creates the exact
defect rev 4's accessibility pass fixed).

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
- **Help audit**: every control has `.help`, and every claimed shortcut resolves
  through `KeyboardShortcutRegistry` (D84) so tooltips can't drift from keys.
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

- **Whether the timeline ever follows the appearance** — deliberately deferred
  until the branded ink deck has lived inside a light window.
- **The words lane at real scale** — thresholds derive from rev 4's
  measurements, but the density ramp and phrase grouping have never been seen
  against a ten-minute narrated transcript. W14 ships them; the first long
  recording judges them.
- **W3's drag behaviour** — the one genuine unknown; fenced as its own PR with a
  named fallback.
- **Whether a `.icon` document can enter the SwiftPM + `make-app.sh` bundle**
  without Xcode — W10 ships the flat rendition either way.
- **Live level ballistics** — the gain ladder shows the level you *set*, not the
  level playing. A live playback meter would ride the 20Hz-protected path;
  deliberately not in this set.
