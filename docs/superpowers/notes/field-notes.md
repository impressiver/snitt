# Field notes

Dated observations from actually using Snitt, and the audit trail for
reprioritization decisions.

**Why this file exists.** D52's discipline was that a milestone does not jump the
queue on a good local argument alone — something had to justify the move. D65
replaced external user evidence with the maintainer's own judgement, which is
faster and better-aimed but only if it is *written down*; otherwise "I want this
next" is exactly the unchecked good local argument D52 existed to catch. So the
substitution is evidence-for-evidence, not evidence-for-nothing.

It is also the project's only home for **what is broken right now**. Until
2026-09-07 that list lived in a chat transcript and nowhere in the repo.

## Format

- `### YYYY-MM-DD` per session of real use.
- **Observation** — what happened, concretely. Not "the timeline is bad" but
  "dragging a 0.4s cut on a 10-minute recording selected 3 seconds".
- **Priority note** — when an observation moves something up or down §13's order,
  say which item and why. That is the audit trail.

---

## Known open — as of 2026-09-07

Carried over from the M5f review. None of these are recorded anywhere else, and
§13 ranks fixing them second, above every new feature, because they are defects
in the surface used daily.

- **An expanded cut fold does not reflow later content.** Expanding a fold in
  place overlaps whatever follows instead of pushing it right.
- **A marker inside a cut is missing from the marker track.** It survives in the
  data (markers are dropped, not clamped, at export) but the track does not draw
  it, so there is no way to see or move it.
- **No on-screen zoom affordance.** Timeline zoom exists and is keyboard-only;
  nothing indicates it is available or what the current level is.
- ~~**Mic and system audio draw as one band.**~~ FIXED 2026-09-07: one band per
  source, derived from `trackStates` so a mic-less recording gets no empty lane,
  and a muted source draws markedly fainter — `TrackState.muted` had been
  changing the export and nothing on screen since M3.

## Needs a human once

- Record with the hotkey and the picker with the microphone **on**. Mic capture
  has been verified non-silent only through the agent path.
- Press the record hotkey and confirm **no window opens on start** (§4.11). The
  editor-on-stop behaviour (D48) is tested; the no-window-on-start half is not.

---

### 2026-09-07

**Priority note.** §13 restructured from milestones to a priority order (D65,
D66). The ordering rationale is in D66: the combination — agentic support,
transcription, focused in-app editing, on-device, open source — is the reason
this exists, so the two members no competitor pairs (the agent surface, local
transcription) rank above the visual polish that CleanShot X and Screen Studio
already ship.

**Priority note.** Crop moved to first. Not because it matters most, but because
it is the cheapest item in the queue by a wide margin — a layer-instruction
transform extending the call `CompositionBuilder` already makes for `--scale` —
and nothing depends on it.

*(No usage observations yet. First entry with real recordings goes here.)*

**Check (2026-09-07) — the repo is clean to open-source.** Run before §13's "pick
a licence" becomes actionable, since D66 makes open source a pillar:

- No key-shaped file appears anywhere in git history.
- The working tree holds nothing credential-shaped. The only two greps that hit
  are `.gitignore` itself and an M5b ledger line recording that `AuthKey_*.p8`
  was added to it.
- `Info.plist` ships `SUPublicEDKey` — the **public** half. The EdDSA private key
  lives in the login Keychain, never in a file, and `.gitignore` nets the export
  filenames anyway.

What is NOT settled by this: going public also publishes `docs/superpowers/`,
including every plan, execution ledger and this file. That is a judgement call
about how much working process to show, not a security question.

### 2026-09-07 (later)

**Observation — a stale incremental build looks exactly like a memory-corruption
bug.** Adding `crop` to `EditDecisionList` changed the layout of a public struct
in `SnittDocument`. SwiftPM's incremental build did not recompile every
dependent, and the resulting binary crashed with SIGSEGV/SIGBUS at a *different*
test each run, generated no crash report, and survived every line-level revert of
the change that "caused" it. `rm -rf .build` fixed it outright.

Cost: about forty minutes of bisection, most of it spent believing the source was
wrong. What eventually pointed the right way was that reverting each individual
line still crashed — the layout change persisted through all of them.

**Rule for next time: when a crash is (a) at a varying location, (b) produces no
crash report, and (c) survives reverting the lines that supposedly cause it,
clean-build BEFORE bisecting further.** Especially after adding or reordering a
stored property on a public struct in a library target.

Worth noting what did work: grepping for `signal code` rather than trusting
`swift test`'s exit status caught it at all. The suite reports success on a
segfault, so the commit would otherwise have gone in green.
