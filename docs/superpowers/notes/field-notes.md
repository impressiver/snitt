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

- ~~**An expanded cut fold does not reflow later content.**~~ ADDRESSED
  2026-09-07, but read the ruling: true reflow was NOT implemented. Moving later
  content would mean an expansion changing `geometry`, the single axis every
  gesture and drawn pixel share — that divergence is M4b's Critical #1 and
  `GestureAxisTests` exists to prevent it. What was actually wrong is narrower:
  the expansion had no right-hand bound, so a long cut's expansion drew over the
  next fold and off the view. `TimelineFoldExtent` clamps it. If reflow is still
  wanted after using it, that is a deliberate change to the axis and needs its
  own decision.
- ~~**A marker inside a cut is missing from the marker track.**~~ FIXED
  2026-09-07: the track now has its own list (`MarkerTrackPoints`) that keeps
  cut-interior markers at the fold and draws them hollow. The jump list still
  drops them, deliberately, and a test asserts the two do not converge.
- ~~**No on-screen zoom affordance.**~~ FIXED 2026-09-07: "+"/"−" buttons in the
  editor's control row, wired to the `zoomIn()`/`zoomOut()` that have existed
  since M5f Task 8 and were reachable only by trackpad pinch or a shortcut on a
  first-responder view.
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

### 2026-09-07 (waveform + filmstrip)

**Built.** Audio tracks draw a waveform, the video track draws a filmstrip, and
the timeline grew 56pt → 120pt to give them room.

**The design decision worth remembering:** both are sampled ONCE against
`capture.mov` in source time, and each pixel column asks
`TimelineSampleIndex` which source instant it shows. So cuts, zoom and scroll
cost nothing — the movie is decoded once per document, not once per edit. It
also means the waveform and the filmstrip agree with each other by construction,
because they use the same mapping.

**Not yet verified against a real recording.** There are no `.snitt` bundles on
this machine — `~/Documents/Snitt` is empty. Everything here is tested against
synthetic fixtures: a sine tone versus silence for the waveform, and the `.ramp`
fill (each frame's pixels encode its index) for the filmstrip. Those catch the
failures that matter — a sampler returning a constant, or every thumbnail taken
from t=0 — but they cannot tell whether a real screen recording's waveform is
*legible*: whether 60 samples/second is enough resolution, whether a desk-mic
track reads at a sensible amplitude next to system audio, or whether 120
thumbnails is too few on a long recording.

**Next session: record something and look at it.** That is the D65 signal, and
these two features are the first work in a while whose quality genuinely cannot
be judged from tests.

## Open — one unattributed intermittent test failure

2026-09-07: a full-suite run failed with a single issue, and the three runs after
it were green. I did not capture WHICH test, so it is unattributed. The suite has
two known load-sensitive families — the real-`SPUUpdater` tests, whose ceilings
were raised 60s to 180s the same day — and this may be a third instance of that
or something else entirely.

**If it recurs, capture the test name before re-running.** A green re-run erases
the evidence, which is what happened here. Worth adding `--verbose` or teeing the
output when a failure appears.

## Manual checklist — for the next session at the machine

Ordered by how much is riding on the answer.

1. **Run the S6 probe: `swift run S6TranscriptionProbe`.** It generates its own
   speech with `say`, so no recording is needed. macOS will prompt for Speech
   Recognition — the grant goes to the *terminal*, not to Snitt.app. The line
   that decides things is `WORD-LEVEL timings present` vs `NOT word-level`. If
   absent, D62's text-based editing is not buildable at the §4.6 floor and
   either the floor moves or the pillar shrinks to captions.

2. **Record something, then open it.** The waveform and filmstrip have never
   been seen. Specifically worth judging, because tests cannot:
   - Is 60 samples/second enough resolution to find a pause by eye?
   - Does the microphone band read at a sensible amplitude beside system audio,
     or is one of them a flat line next to the other?
   - Are 120 thumbnails too few across a long recording — does the strip read as
     motion or as a slideshow?
   - Is the 120pt timeline the right height now that it carries three bands?

3. **Try crop.** Drag on the preview, check the export matches what the editor
   showed, undo it, re-crop (it should compose, not re-anchor), and `Reset Crop`.
   Then the same through the CLI: `snitt crop <bundle> --x 0.25 --y 0.25
   --width 0.5 --height 0.5` and `--reset`.

4. **The two long-standing human-only checks** (carried since M5f):
   - Record with the hotkey and the picker with the microphone ON. Mic capture
     has only ever been verified through the agent path.
   - Press the record hotkey and confirm **no window opens on start** (§4.11).
     The editor-on-stop half (D48) is tested; this half is not.

### 2026-09-08

**Observation (product owner):** recorded a real voiceover; the mic waveform
existed but nothing indicated a transcription surface (there is none — D62 is
unbuilt, gated on S6).

**Priority note:** direction from the same session — log-scale the waveform,
mark clipping, add per-track gain/volume. Built same day. Measured against the
actual recording: the loudest bar moves from 23% of the band (linear) to 79%
(log, -60 dB floor), the mean from 2% to 35%. The recording is clean — zero
clipped buckets even at 4x gain — so the clipping marks will appear only when
earned. `TrackState.gain` had been applied by the export mix since M3 with no
way to set it; the same model-without-a-surface shape crop had.

### 2026-09-08 (later)

**D62 first slice built.** The editor transcribes on open (when the Speech
grant exists — the pane offers a Transcribe button the first time), and the
transcript is an editing surface: click a word to seek, shift-click to select a
phrase, Delete Words to cut its seconds. Cut words strike through, derived from
the EDL, so a timeline cut strikes text and undoing un-strikes it.

**The production path ran against the real recording** and wrote its
transcript.json — opening `Snitt-1788888317.snitt` shows the 16 words
immediately. Low-confidence words draw dimmed ("loom is" at 0.34 — probably
"Loom is"); there is no in-place correction yet.

**Worth judging by eye:** the pane is a fixed 250pt beside the player; whether
strike-through reads clearly at callout size; whether click-to-seek feels right
or should audition a couple of words around the click.

### 2026-09-08 (transcript gap)

**Observation (product owner):** "the transcript is missing the first ~10s".
Correct, and I had reported the cause backwards — I read the transcript starting
at 11.28s as *the recording being silent until then* and wrote that into D68 as
evidence the recognizer handled long silences.

**Root cause, measured not guessed.** Per-second mic peaks showed signal across
the WHOLE recording (the loudest second, 0.23, was one the recognizer never
returned), and the extracted track matched, so the loss was in recognition.
Logging every result the recognizer emits showed it plainly: partials climb
through the first utterance, restart for the second, and the single `isFinal`
carries only the second. Timestamps are 0 on every partial, so accumulating
them is not an option when word timings are the point.

**Rule this reinforces:** an absence in output is not evidence of absence in
input. Both times I have trusted a "the data just isn't there" reading this
session (the `~/Desktop` permission error, now this) it was wrong — and both
times one measurement of the *input* settled it in under a minute.
