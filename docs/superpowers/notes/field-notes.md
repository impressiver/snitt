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

*S6 is done (D68). What follows is ordered by whether it needs a new recording.*

### A. Answerable right now, from recordings already on disk

**A1 — `open ~/Documents/Snitt/Snitt-1788888317.snitt`** (20.9s, voiceover, a
33-word transcript, one cut). This is the only bundle that exercises nearly
everything built since, all at once:

- **Waveform legibility.** The mic peaked at 0.231, which the log scale draws at
  79% of the band. Is a pause findable by eye? Is 60 samples/second enough?
- **Transcript pane.** 33 words, already transcribed. Click a word — does the
  preview land where it was said? Press play — does the highlight track, and
  does the pane scroll only while playing?
- **Correction.** Double-click "loom is" (dimmed, confidence 0.34) and type
  "Loom is". It should stop being dimmed. ⌘Z should restore BOTH the text and
  the dimming.
- **Text deletion.** Select a phrase, Delete Words. It should become a red fold
  on the timeline and undo on the same stack.
- **Fold expansion.** Expand the existing cut. Later content should shift right
  and the playhead should JUMP the band, not crawl through it. Clicking the red
  band should collapse it.
- **Gain.** Drag the mic slider. The waveform should redraw as you drag, and go
  red if you push it into clipping.
- **Crop.** Drag on the preview, export, undo, re-crop (it should compose, not
  re-anchor), Reset Crop.

**A2 — `open ~/Documents/Snitt/Snitt-1788896932.snitt`** (200s, no audio). The
only long recording: does the filmstrip read as motion or as a slideshow at 120
frames across three and a half minutes? Its audio bands will be flat, which is
correct and is itself worth seeing.

**A3 — the CLI half of crop**, which has never been run by hand:
`snitt crop ~/Documents/Snitt/Snitt-1788888317.snitt --x 0.25 --y 0.25
--width 0.5 --height 0.5`, then `--reset`.

### B. Needs a new recording

**B1 — the two human-only checks carried since M5f.** Press the record hotkey:
**no window should open** (§4.11 — the editor-on-stop half is tested, this half
never has been). Pick a target with the microphone ON, and confirm the mic band
is not flat afterwards. Mic capture has only ever been verified through the
agent path.

**B2 — is system audio captured at all?** Every one of the five recordings on
disk has `systemAudioRMS` exactly 0. That is plausible — none of them obviously
made a sound — but it means the path has no positive evidence anywhere. Play
something audible for a few seconds while recording, then check the system-audio
band is not a flat line.

**B3 — a LONG narrated recording**, if you want the open performance question
answered: does a ~1500-word transcript still highlight smoothly at 20Hz? No
existing recording has both length and voiceover, so nothing on disk can answer
it. The fix, if it stutters, is to stop re-rendering every word per tick rather
than to slow the clock.

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

### 2026-09-08 (playback highlighting)

**Built.** The transcript word being spoken highlights as playback reaches it,
and the pane scrolls to follow — but only while actually playing, so reading and
selecting is never dragged out from under you.

**Open question that needs a long recording to answer.** The playhead poll went
from 10Hz to 20Hz, because the recognizer emits words as short as 0.06s ("the",
in the first real recording) and at 10Hz those were skipped entirely. Each tick
re-renders the transcript pane. At 33 words that is free; at ~1500 words (a
ten-minute narrated demo) it may stutter, and the fix would be to stop
re-rendering every word on every tick rather than to slow the clock back down.
**Worth watching the first time a long recording is open and playing.**

**Also worth an eye:** selection is the accent fill and the playhead is a yellow
tint, with bold carrying the playhead when a word is both. Whether that reads
clearly, or whether the two states still compete, is a judgement the tests
cannot make.

### 2026-09-08 (expanded folds reflow)

**Reversal, on product-owner direction:** "the playhead should skip over
expanded cut sections". Expanded folds now INSERT their space into the timeline
axis, so content after them shifts right and the playhead jumps the band rather
than appearing to travel through removed footage.

**This overturns a decision I made and defended twice this session** — that
expansion must not move `geometry`, on the grounds that a UI-only change to the
shared axis is M4b's Critical #1. The reasoning was wrong in a specific way:
the danger is drawing and hit-testing using DIFFERENT axes, not the axis having
a new term. One mapping with an inserted-space term, used by both, is coherent —
and `ExpandedFoldAxisTests` now asserts a click after an expanded fold lands on
the instant drawn there.

`TimelineFoldExtent` was deleted. It existed only to stop an expanded band
drawing over the next fold, which reflow prevents at its source; clamping now
would draw a band narrower than the space the axis reserved.

**Judgement call worth an eye:** at the default zoom, fit-to-view now includes
inserted space, so expanding a fold shrinks everything slightly to make room
rather than pushing later content off the right edge (where nothing scrolls at
1x, so it would be unreachable). Whether that rescale reads as helpful or as
the timeline jumping about is something only using it will tell.

### 2026-09-08 (expanded band drawn in the wrong place)

**Observation (product owner):** clicking just before an expanded cut did not
land where it was drawn.

**Root cause:** I drew the band at `x(atFold:)`, which after the reflow change
is the instant the cut collapsed TO — the band's *trailing* edge, the first
surviving frame. So the band sat one full width to the right of the space the
axis had reserved: blank gap where the removed footage should be, red rectangle
painted over the content that follows, and every click near it incoherent.

Measured, not reasoned about: printing the gap (x 50–90) against `x(atFold:)`
(90) showed it in one line, after a couple of minutes spent theorising about
which direction the playhead would move.

**Shape worth remembering:** "where is the fold" and "where is its band" are
different questions, and reflow made them different ANSWERS. My own axis test
passed throughout, because it only checked `x(atOutput:)` against clicks — it
never asked where the rectangle was drawn.

### 2026-09-08 (first agent-driven recording)

**§13's second validation question got its first real answer**: an agent drove
Snitt over MCP end to end — start, mark, stop, export with chapters — and
produced an 88s recording with five chapters. That worked.

**It also found a real defect on the first try.** Asked to record Chrome with
ten windows open, `snitt_start_recording` recorded a private pull-request diff:
the resolver returns the LARGEST matching window and the agent had no way to say
which one it meant. Fixed by D69 — `windowID`, and refusing ambiguity rather
than guessing.

**What makes this worth remembering** is that the design already knew.
`TargetSummary` carried the window id, `titleHint` existed for exactly this
disambiguation, and §8 documented `--window-id` from the start. Three separate
pieces of the answer were present and none was wired to the others. A feature
can be fully specified, partly built, and still broken in the way it was
specified to avoid.

**Open, from the same session:** the agent had to launch Snitt.app itself
because it was not running. Whether an agent should auto-launch the app — which
then holds a screen-recording grant on its initiative — is a §5 question nobody
has decided. §4.9's current answer is the client saying "ask the person at the
machine to open it".
### 2026-09-08 (in-window exposure)

**Observation, from the second agent recording session:** the agent went to
record a Chrome window and noticed it also held a Namecheap order confirmation
and a Carta login — whose tab titles would have been in every frame. It moved
the page to its own window to avoid that, which took several steps of AppleScript
window choreography.

It got this right unprompted. The next one may not, so the warning is now in
`snitt_start_recording`'s description and the CLI usage.

**The real question is recorded as D70 and is yours to rule on:** whether
capture should be able to exclude part of a window (`SCStreamConfiguration.
sourceRect`). It is a stronger guarantee than cropping at export, because the
BUNDLE stays clean rather than just the exported file — and it contradicts
§4.5's pristine-capture principle, deliberately. Nothing was built for it.

### 2026-09-08 (the agent could not scroll)

**Observation:** the agent could not scroll the article it was demonstrating —
its own control tool is allowlisted per domain and that domain was not listed —
so the recording shows the page static for ~20s.

**Investigated, recorded as D71, open for a ruling.** The interesting part is
not the friction, it is that D49's stated reason for refusing to drive input
turns out to be narrower than the ruling built on it. Posting via `CGEvent`
needs Accessibility and is all-or-nothing, exactly as D49 says. Apple Events
scripting is a separate grant, per source→target app pair, visible and revocable
in Settings ▸ Privacy ▸ Automation — and can scroll a scriptable app without
Accessibility at all.

So "scroll the window you already consented to film, while filming it, with a
marker at the same instant" is expressible with a much smaller grant than D49
assumed any control surface would need. Whether to want it is still a product
call. Nothing built.

### 2026-09-08 (rulings on D70 and D71)

Both deferred by the product owner, with triggers named so a later session does
not re-litigate them:

- **D70 (excluding part of a window at capture):** leave it; build it if it is
  asked for. The shipped warning is the response. Reopen when somebody has a
  bundle they cannot share because of what its chrome captured.
- **D71 (Snitt scrolling the recorded window):** agents should handle their own
  scrolling. Reopen only on RECURRING friction across different agents and
  tools — the instance that prompted the investigation was a missing domain in
  one agent's own allowlist, which is its gap and not Snitt's.

Worth keeping straight: D71's investigation stands even though the ruling is
"no". It found that D49's stated premise — that driving input needs the global
Accessibility grant — is too narrow, since Apple Events scripting is per-app and
revocable. That changes what is POSSIBLE, not what is wanted, and it is written
down so a future reopen starts from the real constraint rather than the old one.

### 2026-09-09 (what a GitHub runner cannot run)

The first CI run that got past compiling revealed which tests need a real Mac.
670 finished, then the job stalled for 37 minutes until its timeout. The 254
that never returned map to `SnittExportTests` and `SnittAppTests` only, and
they share one property: they build an AVFoundation composition, encode a
movie, or open a window.

A GitHub-hosted macOS runner is headless and has no hardware video encoder, so
that work does not finish — it does not fail, which would have been easier; it
hangs, and Swift Testing's parallelism means one blocked primitive takes 254
tests down with it.

CI now runs the five targets that do work — document model, capture,
automation, CLI, MCP: 475 tests in about ten seconds. **Export, composition,
the editor and the timeline are verified locally only.** `swift test` unfiltered
remains the gate before a release.

Two costs worth remembering. That diagnosis burned ~40 minutes of macOS runner
time, billed at 10x on a private repo. And several runs before it were
CANCELLED rather than completed, because `concurrency: cancel-in-progress`
supersedes a run on every push — correct behaviour, and confusing when you are
waiting on a result that was never going to arrive.

### 2026-09-08 (the plan lagged the code three times in one day)

`§13`'s "Next, in order" listed built work as pending three separate times, and
each was found only by checking before starting:

- **Crop** sat at position 1 as "the cheapest item in the queue" a day after it
  shipped with live preview, undo, `CropRect.composing` and a CLI verb.
- **D73's speaker-bleed warning** was listed as not-yet-built while being built
  the same afternoon — that one is ordinary lag.
- **M5e's agent primitives** were all present: pause/resume, screenshot,
  WebVTT subtitles, `paused` state, and the screenshot-marks-the-frame
  correlation guarantee. **S5, which supposedly gates M5e, had three of its
  four premises stale too** — the bundle already embedded both binaries,
  `snitt setup` already existed, and the `instructions` field it called "cheap
  and unblocked" was already set.

D47's conformance guard does not catch this. It checks that §-refs and D-refs
RESOLVE, not whether a "next" item describes work that is done — and no cheap
mechanical check does, because "is this built?" is not answerable from prose.

The working countermeasure is behavioural and it earned its keep every time:
**read the item's premises against the code before starting it.** Twice today
that turned a planned build into a five-minute correction, and once (S5) it
redirected the work entirely — from "decide how to register an MCP server" to
"the prose describing it has gone stale and nothing guards it."

### 2026-09-08 (a documented threshold whose evidence has expired)

`fileLengthLimitAloneShrinksTheFile` failed once in three full-suite runs and
passed 5/5 standalone: 486,801 bytes against a 470,595 bound, ratio 0.931.

The threshold is not arbitrary — its comment records a mutation-derived basis:
true-positive ratios "mostly 0.30-0.50, reached as high as 0.79 twice under
heavy contention", no-op ratios "0.97-1.0", and 0.90 chosen to sit ~0.11 above
one and ~0.07 below the other.

**Today's true positive was 0.931, above that recorded ceiling.** The gap the
threshold lives in has narrowed from ~0.18 to ~0.04 as the suite grew to a
thousand tests and contention rose. Left ALONE deliberately: widening 0.90 on a
single observation would erase a decision derived from ~30 measured runs, and
the honest fix is to re-derive the distribution, not to nudge the number until
it stops failing.

### 2026-09-09 (a second batch of editor defects, all reported by use)

Five observations from the product owner in one session, all from actually
driving the editor rather than from reading code. Four were fixed the same day
(D82, D85, D87, D88); four more were recorded as queued enhancements and
deliberately not built (D83, D84, D86, D89).

**The pattern worth naming: three of the four defects were invisible to a green
suite because each was about a SEQUENCE, not a value.**

- A dragged marker reverted until the timeline was clicked again. `events` was
  correct the whole time; a cache read during the synchronous re-render was not.
  Every test asserting "the marker moved" passed.
- Crop applied on mouse-up, so there was no adjustable state to be wrong about.
  The geometry was right; the interaction had no second step.
- Adjusting gain reset the playhead. The gain reached the mix, the mix reached
  the export, `edit.json` was correct. What was wrong was that a volume change
  rebuilt the whole composition and `replaceCurrentItem` threw the position
  away.

None of these is a wrong number. They are wrong *orders* and wrong *lifetimes*,
which is the class a value-asserting test cannot see. What caught them was
someone using the thing.

**A test that passed against both implementations.** Writing D82, I justified
the atomic chapter edit with undo — "two registrations means one ⌘Z restores
half the edit" — and wrote a test to prove it. The test passed against the
implementation it was supposed to reject. `UndoManager.groupsByEvent` is on by
default and collapses registrations made in one run-loop pass, so both versions
undo identically. The honest reasons survived (two writes of `events.json`; a
published frame carrying the new time with the old name) and
`oneEditPublishesOnce` discriminates. **Rule: when a mutation test passes, check
it fails against the mutant before believing the claim in the comment.** The
mutation step is what caught this; the reasoning did not.

**A trap found while fixing D88.** Applying an audio mix in place, a nil mix
must be ASSIGNED, not skipped. `CompositionBuilder.audioMix(for:edl:)` returns
nil for "nothing to express", and reading that as "nothing to do" leaves the
previous mix installed — so un-muting a track would leave it silent forever,
with an EDL saying it is fine and a slider reading 1.0.

### 2026-09-09 (CI is blocked on billing, not on code)

After four PRs merged green, the fifth's jobs failed in 2-7 seconds with **zero
steps recorded**. That shape — no steps, instant failure, every job — is a
runner that never started, not a check that failed. The run annotation says it
outright: *"The job was not started because recent account payments have failed
or your spending limit needs to be increased."*

macOS minutes bill at 10x on a private repo and this session ran five PRs
through them.

**Worth remembering: a job with zero steps is an infrastructure failure.** Read
the run annotations (`gh api repos/OWNER/REPO/check-runs/ID/annotations`) before
looking at the diff. The job logs themselves had already expired to
`BlobNotFound`, which sends you looking at the code for a cause that was never
there.

The substitute, when CI cannot run: CI's checks are all reproducible locally —
the hygiene steps are greps, and the test step is a filter. Running them by hand
on the merge candidate is honest evidence, but it is a local machine, not a
clean `macos-26` runner.

**Also corrected here:** the entry above says CI runs 475 tests. It runs 492 as
of 2026-09-09.

### 2026-09-09 (Dependabot's three major action bumps)

`actions/checkout` 4→7, `actions/cache` 4→6, `actions/upload-artifact` 4→7 —
all merged. The majors they cross are almost entirely Node 24 runtime moves and
ESM migrations, which matter only for self-hosted runners (this repo has none).
The two substantive changes, neither of which bites here:

- checkout v7 blocks fork checkout for `pull_request_target` and
  `workflow_run`. This workflow triggers on `push` and `pull_request` only.
- upload-artifact v7 adds an opt-in `archive: false` for direct single-file
  uploads. It defaults to true, so `name`/`path` behave as on v4.

**A friction worth writing down:** merging a PR that touches
`.github/workflows/` needs the `workflow` OAuth scope. `gh` had `repo` but not
`workflow`, and the merge was refused by the API with a message that reads like
a permissions bug rather than a missing scope. Fix is
`gh auth refresh -h github.com -s workflow` — and `-h` is required when it is
not attached to a tty.

Expect one cold cache on the first run after the `cache` major: bumping it
changes the internal cache version, so the existing `spm-*` entries will not
restore.

### 2026-09-09 (a test gate that could hang forever)

**Observation (product owner):** "test suite seems to be stuck." It was — a full
unfiltered `swift test` sat at **0% CPU for over ten minutes** and had to be
killed. No output, no failing test, nothing to read.

**Two hypotheses, both wrong, both killed by one measurement each.**

1. *"`--filter` has been silently skipping these tests all session."*
   `swift test --list-tests` says all 1143 tests match the filter. Nothing was
   being skipped. Refuted in one command.
2. *"These unit tests reach the network and a DNS stall hangs them."* Plausible
   — a `sample` of the hung process showed `Sparkle` and
   `URLSessionTransportInternal` frames, and the fixture's `SUFeedURL` was
   `https://example.invalid`. But `UpdaterControllerTests` runs in **1.99s** in
   isolation and `example.invalid` NXDOMAINs in **0.02s**. The network is not
   the cost.

**What it actually was.** `SparkleTestGate.acquire()` waited on a
`CheckedContinuation` with **no ceiling**. One holder that never finishes blocks
every other gated test forever. And the ~86s figures that pointed me at Sparkle
were not Sparkle at all: **214 of 1143 tests report 60s or more**, spread across
audit paths, transcription, pause/resume, marker drags and window geometry.
Nearly all of it is queueing behind gates, not working.

**The fix does not make anything faster, and should not be sold as if it did.**
The duration distribution afterwards is 213 tests ≥60s, against 214 before. What
changed is the failure MODE: a stuck holder now fails its waiters with a message
naming the holder, instead of hanging them.

**The rule worth keeping: a hang is the worst shape a failure can take.** It is
indistinguishable from ordinary slow progress, it costs the whole run instead of
one test, and it names nobody. A bounded wait that occasionally fails early is
strictly better — that failure is loud, points at a culprit, and lets the other
1145 tests finish. Note which direction the risk runs before choosing a ceiling.

**Still carrying the same defect (not fixed here):**
`EditorWindowTestGate` (`Sources/SnittApp/EditorWindowController.swift:1983`) and
the queue in `RecordingCoordinatorTests.swift:47` are the same unbounded
`withCheckedContinuation` shape. `EditorWindowTestGate` guards far more tests
than the Sparkle gate does, so it is the bigger exposure of the two.

### 2026-09-09 (why the suite is slow — and why the obvious fix was only worth 10%)

**The "214 tests take ≥60s" figure is an artifact, not a finding.** Swift Testing
schedules every test concurrently and reports wall-clock from SCHEDULING, so a
test's number is mostly time spent queued. The proof is arithmetic: in an
isolated run the slowest single test took **56.817s** and the entire run took
**56.817s**. A test cannot outlast the run containing it. `TimelineViewTests`
settles it independently — 25 tests in **0.076s** alone, yet 14 of them report
≥60s in the full run.

**Where the wall clock actually goes.** The suite uses **0.59 cores of 10**
(35.8s CPU across 60.4s wall), so it is waiting, not computing. Sampling
mid-run: `WindowServer` 44% (real `NSWindow`s), `OSLogService` 44.7%,
`VTEncoderXPCService` 18.7% (real H.264 encode). The work is out of process,
which is exactly why in-process CPU looks idle.

**Explicit sleeps are NOT the cause** — 3.8s across 16 call sites, against ~60s
of runtime. Worth checking before believing it.

**Logging is not the lever it looks like.** `OS_ACTIVITY_MODE=disable` saved
~10% (58.7s → 52.7s) and **broke 3 tests** that genuinely assert on log readback
(S8). Not safely removable.

**The fixture cache: predicted 3-4x, delivered 10%.** `writeSyntheticMovie` had
40 call sites each encoding a fresh `.mov`; caching by parameters and copying
took the full suite from ~102s to ~87-93s. Per-suite it ranges from **-54%**
(`CutFoldTests`, fixture-dominated) to **-1%** (`AutomationHostTests`, which
waits on IPC instead). I predicted the suite would drop to 15-20s. It did not,
and the reason is instructive: the encode was already happening out-of-process
and overlapping with other work, so removing it recovered far less than its
nominal cost. **Nominal cost is not wall-clock cost when the work is
concurrent** — measure the total, not the part.

**The real remaining lever is cross-target interference, and it is bigger than
everything above.** SnittAppTests alone is 52.4s. SnittExportTests alone is
8.8s. Together with the other five targets the full suite is ~87-93s — roughly
**30 seconds that belong to neither target**, spent contending for the
MainActor, the WindowServer and the video encoder. No amount of fixture caching
touches that; it is a consequence of running one process with 38 of 62 app-test
files on `@MainActor`, 28 `.serialized` suites, and three global gates.
