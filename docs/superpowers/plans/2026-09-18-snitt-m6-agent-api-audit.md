# Agent API audit, and the work it implies

## Context

Snitt's README leads with "a native macOS screen recorder that **a coding agent
can drive**", and §4.8 makes that a product pillar with a moat: no competitor
ships an agent surface at all (D66). This audit asks whether that surface is
clean, correct, intuitive and frictionless.

**Verdict: the design is strong and the agent-facing frontend is the weak half.**

The tool descriptions are unusually good. They explain failure modes rather than
restating parameter names: `snitt_start_recording` warns that a browser's tab
strip puts every other tab title into every frame; `windowID` says Snitt refuses
rather than guesses "because guessing records whichever window is largest and
you will not find out until you watch the result"; keystroke reporting carries
no label by design, so timing is recorded and content never is;
`snitt_auto_deep_trim` states that running it twice is safe;
`snitt_estimate_export` says its size is an upper bound rather than a
prediction. Very little API writing is this careful.

The problems are almost all in one place, and they rhyme.

## The finding that explains most of the others

**No output contract was ever written for the MCP server.** This is a gap in the
spec, not a breach of it, and an earlier draft of this audit got that wrong.

§4.8 does state an "agent-facing output contract: structured JSON on stdout,
human-readable text on stderr, meaningful exit codes", which reads like a rule
both frontends must meet. It is not. §15 scopes it: "**the CLI's** JSON output
and exit codes are a public interface with agents as consumers; they get
snapshot tests. The MCP server and CLI are tested against the same
`SnittAutomation` fixtures to prove they cannot diverge."

So the contract is the CLI's, and "cannot diverge" is operationalised as shared
fixtures through `SnittAutomation`, which is the **request-building** layer that
both frontends genuinely do share. Response rendering was never covered. The
wording is CLI-shaped for a good reason: an MCP server has no per-call exit code
and no stdout/stderr split at all.

That matters because it changes the fix from "restore a broken rule" to "decide
a rule that was never made". The consequences below are real either way.

`snitt-cli/main.swift` honours the contract for every case: `emit(JSON)` to
stdout, `note(prose)` to stderr. `snitt-mcp/main.swift`'s `describe(_:)` returns
**encoded JSON for exactly two cases** (`.targets`, `.status`) and **prose for
the rest** (`.started`, `.stopped`, `.inspected`, `.marked`, `.failure`). So an
agent can `JSON.parse` two tool results and must pattern-match sentences for the
others.

That is not cosmetic. `sessionId` is required by six tools and `bundlePath` by
seven, and both are returned only inside a sentence: `"Recording <target>.
Session id: <id>"`, `"Saved <path> (metrics)"`. Every subsequent call in the
loop begins by extracting an identifier from prose.

The sharpest instance is `snitt_inspect`. `InspectReport`'s own doc comment says
it exists "so an agent can write something factually true in a pull request
instead of narrating a recording it has never seen." The CLI emits the whole
report. The MCP path renders duration, marker count and labels, and **drops
capture health and git context**. The struct built to stop agents fabricating
has its agent frontend discard the evidence.

## Findings

Ranked by how badly each misleads a screen-blind caller. **Every finding below
is CONFIRMED: I opened and read each cited line myself**, including the ones
reviewers first raised. Two claims from review were checked and did not survive,
and are recorded as corrections rather than findings: that §4.8's output
contract is breached (it is CLI-scoped, see above), and that agent-authored
narration is out of scope (it is not, see PR F).

One thing is explicitly NOT verified and is marked where it appears: whether the
app's own UI surfaces orphaned bundles, which would make the cleanup gap
agent-API-only rather than product-wide.

### 0. The agent cannot see

- **`snitt_screenshot` never returns an image.** CONFIRMED, and this is the
  worst finding here. Its description says "Use it to SEE the window you are
  recording, you cannot watch the video, and this is the only way to check the
  demo looks right while it is still fixable." What it returns is a sentence
  containing a filesystem path (`snitt-mcp/main.swift:103`). There is no `image`
  content block anywhere in the MCP surface: grepping `"image"`, `base64` and
  `mimeType` across `snitt-mcp/main.swift` and `MCPBridge.swift` returns
  nothing.

  So the one tool built to make a screen-blind agent not blind works only if the
  calling host happens to expose a separate multimodal file reader, which is
  outside Snitt's contract and which the tool never mentions. Every failure the
  other descriptions carefully warn about (a browser's tab strip, the wrong
  window, a dialog over the target, a black frame) is visual, and none of them
  is detectable from a path.

  The code comment beside it is unintentionally sharp: it puts the timestamp in
  the text rather than only the filename because "reading it back out of a path
  is work it should not have to do." The image is left as a path.

### 1. Silent wrong answers

These succeed while doing something other than what was asked. §8 forbids
exactly this.

- **`subtitles` silently coerces to `false`.** CONFIRMED.
  `MCPBridge.swift:917` is `(arguments["subtitles"] as? Bool) ?? false`, while
  `chapters` and `clicks` in the same function go through `booleanValue()`.
  **This is the third round of one bug.** That helper's doc comment says two
  earlier rounds hardened `numericValue`/`displayID`, then `autoTrim` and
  `chapters` stayed on the bad pattern, so `{"chapters": "true"}` "exported
  successfully with no chapters and no error, indistinguishable from a recording
  that genuinely had none. Both are exactly the confidently-wrong outcome §8
  forbids." `subtitles` was never migrated, and has no coercion test.
- **Every MCP recording loses git context.** CONFIRMED. The
  `snitt_start_recording` handler sets seven fields and never
  `options.workingDirectory`, whose doc comment says it is "used to discover git
  context (§7)" and is "filled by the CLI, not the app". The bridge already
  receives a `workingDirectory` argument and uses it to resolve paths for five
  other tools. So the feature that attributes a demo to the commit it
  demonstrates works for humans on the CLI and is dropped for agents.
- **Vocabulary truncation is silent, against a written promise.** CONFIRMED.
  `Vocabulary.swift:29`: "Truncating is reported rather than silent, see
  `prepare`." `prepare` duly returns `(terms, dropped)`. The only agent call
  site, `AutomationHost.swift:945`, reads `.terms` and discards `.dropped`, and
  no response field carries it. List 150 terms, get a normal success, never
  learn that 50 never reached the recogniser.

### 2. The output contract

- **`describe(_:)` returns prose for most cases.** CONFIRMED. Not a rule
  violation (see above), but the practical cost stands on its own: `sessionId`
  and `bundlePath` are required across thirteen tool signatures and come back
  only inside sentences, so every call after the first begins by extracting an
  identifier from prose. MCP's own `structuredContent` exists for this, and the
  prose can stay as the text block.
- **Argument errors carry no code at all.** CONFIRMED in shape: a tool result is
  a hand-built dict, `["content": [["type": "text", "text": text]]]` plus
  `isError` (`snitt-mcp/main.swift:35,47`), so there is nowhere for a code to
  travel. `MCPBridgeError` therefore renders as bare text while a real
  `AutomationError` renders code-prefixed, and `Protocol.swift:225` says "An
  agent branches on this [code], never on `message`". The taxonomy does not
  reach the largest class of real mistakes.
- **`internal_error` is a catch-all across three unrelated classes.** CONFIRMED:
  27 sites in `AutomationHost` alone, 39 across `Sources`. It spans
  caller-fixable validation, permanently unusable data, and transient conditions
  whose own hint says to try again in a moment. One code, one exit code, for
  "fix your request", "do not retry", and "wait and retry".

### 3. Friction

- **A normalized-coordinate tax, and it is systemic.** CONFIRMED.
  `snitt_crop` takes 0-1 fractions **and returns pixel dimensions**;
  `snitt_report_input` takes 0-1 fractions and tells the caller to "compute them
  from the element's position plus the browser's own chrome offset". Both make
  the agent do arithmetic from numbers it holds in pixels, and `CropRect` clamps
  rather than throws, so getting it wrong is silent. Nothing earlier in the loop
  even reports the frame's pixel size: it appears only in `CropSummary`, after
  you have already cropped.
- **`clicks` defaults to off.** CONFIRMED. The server instructions justify
  `snitt_report_input` entirely on visibility ("unwatchable as a demo"), then
  export draws those clicks only if the agent opts in a second time. An agent
  that follows the loop faithfully still ships the demo the loop exists to
  prevent.
- **`snitt_estimate_export` is mp4 only.** CONFIRMED. GIF is the format whose
  size ladder silently degrades to 5fps, so the format that most needs an
  estimate is the one estimate refuses. This is issue **#160**.
- **Two trim calls for one conceptual step.** CONFIRMED. The server's own
  instructions describe "tidy up" as one step, and it costs `snitt_trim`
  (a boolean `autoTrim`) plus `snitt_auto_deep_trim` (a preset plus five
  numeric overrides): two calls, two unrelated parameter vocabularies, on every
  recording.
- **No way to see before cropping.** CONFIRMED. The documented loop says to crop
  away private chrome at step 5 and never says to screenshot first, which is the
  only way to know where the chrome is. Compounds finding 0.

### 3a. A consent dimension nothing covers

- **No grant authorises frame pixels leaving the machine.** CONFIRMED.
  `ConsentPolicy.evaluate` checks `agentRecordingEnabled`, `fullDisplayAllowed`
  and target presence; `screenshotForAgent` additionally checks that the agent
  owns the session. All three authorise *recording*, and none contemplates
  onward transmission of frame content. Today that gap is inert, because the
  tool returns a path. It stops being inert the moment an image block is added,
  which is why PR A makes it opt-in.

### 3b. Consent can only be discovered by failing

- **Nothing reports grant state before you attempt work.** CONFIRMED.
  `StatusInfo` carries `recording`, `sessionID`, `elapsedSeconds`, `paused` and
  `pausedSeconds`, and nothing about consent. So an agent learns that agent
  recording is switched off, or that full-display capture was never enabled, by
  calling a tool and receiving `consent_required`. The error itself is
  well-hinted, so this is a gap rather than a trap, but a pre-flight field costs
  almost nothing and saves a failed call on every cold start.

### 4. Reach

- **The agent API cannot caption or annotate a video.** CONFIRMED.
  `showSubtitles` and `showMarkers` appear nowhere in `SnittAutomation`. There
  are two different "subtitles" in the product: the `subtitles` flag writes a
  sidecar from **marker transcripts**, while burned-in captions come from the
  **speech transcript**. An agent can record speech, have it transcribed on
  device, and still have no way to put it on the video. This is why the README
  demo plan resorted to hand-writing `edit.json`.
- **No transcript access at all.** CONFIRMED by absence. No tool reads the
  transcript or writes authored narration.
- **Nothing lists or cleans up past recordings.** CONFIRMED by enumerating all
  16 tools. A watchdog exists and is good: `AutomationHost.swift:1131` notes
  "an agent that crashes after `record start` left `AVAssetWriter` writing until
  the disk filled", and `armWatchdog`/`expire` force-stop and still finalise a
  bundle, recording `AuditOutcome.capped`. But the bundle it leaves is then
  invisible to the API: `snitt_status` reports only whether a recording is
  running *now*, and no tool lists or removes prior bundles. An agent that
  crashes twice has two full-resolution videos it cannot find. A minimal
  `snitt_list_recordings` (path, size, age, capped or completed) would close it.
  Not verified: whether the app's own UI surfaces these, so this may be an
  agent-API gap rather than a product-wide one.
- **`vocabulary` is MCP-only; `reportInput`'s `label` is CLI-impossible and
  undeclared in the MCP schema.** CONFIRMED: `vocabulary` appears zero times in
  `CommandLineParser.swift`, and `snitt-cli/main.swift:242` hardcodes
  `label: nil`. The MCP schema for `snitt_report_input` declares only
  `sessionId`, `kind`, `x`, `y`, though the handler reads `label`.

### 5. Naming and polish

- `mark` (protocol) vs `record mark` (CLI) vs `snitt_add_marker` (MCP).
  CONFIRMED: the only pair that does not share a verb.
- `estimate` (CLI) vs `snitt_estimate_export` (MCP). CONFIRMED.
- CLI `estimate --format` is a vestigial flag that accepts only `mp4`
  (`CommandLineParser.swift:214` refuses anything else); MCP has no such
  parameter and hardcodes it. CONFIRMED.
- `maxDurationSeconds`, `microphone` and `systemAudio` carry no descriptions
  while every other parameter is richly documented. CONFIRMED.

## What holds up

Worth stating, so the fixes stay proportionate:

- `CropRect` clamps rather than throws, but `CropSummary` returns the **applied**
  rect, so the adjustment is visible rather than silent.
- `trim` is genuinely idempotent and preserves prior cuts (this was D60's
  data-loss bug, and it stayed fixed).
- The CLI surfaces `code`, `message` and `hint` with stable distinct exit codes,
  and separates "not running" from "running but stuck" from "malformed
  response".
- The privacy posture is real: keystrokes record timing and never content, and
  diagnostics exclude window titles and paths.

## The work, in order

Each its own PR, merged before the next.

**Most of this work is CI-gated, unlike the demo plan's features.** CI runs
`SnittDocumentTests`, `SnittCaptureTests`, `SnittAutomationTests`,
`SnittCLITests` and `SnittMCPTests` (`ci.yml:172`); only `SnittExportTests` and
`SnittAppTests` hang headless. `MCPBridge`, `Protocol` and the two frontends all
live in gated targets, so PRs C, D and G are covered by a normal PR check. The
exceptions are the parts touching `AutomationHost` (PR B's vocabulary fix, PR E)
and all of PR F, which reach into `SnittApp` and `SnittExport` and therefore
still need a local `Scripts/run-tests.sh` before merge.

That makes this audit's work materially cheaper and safer to land than the
feature PRs the demo plan proposed, which is an argument for doing it first.

1. **PR A: let the agent actually see the frame.** `snitt_screenshot` returns an
   MCP `image` content block alongside the existing text, instead of a path only.

   **It leads on importance** because it is the only item that changes what an
   agent can KNOW about the artefact it is about to ship, rather than how well it
   drives the tool. The failure modes Snitt's own descriptions warn about (a
   browser's tab strip, the wrong window, a dialog over the target) are visual,
   and no structured metadata substitutes for looking.

   **It does not lead on sequence, because it is not yet specified.** Review
   caught that this plan said "return an image" with no resolution policy at all.
   `ScreenshotWriter.swift:31` builds the CGImage from `ciImage.extent`, the
   buffer's native pixel size, and neither it nor
   `RecordingCoordinator.screenshotForAgent` has a resize path or a scale
   parameter. On a Retina or 5K display that is a very large PNG, base64 adds
   about a third again, and the loop calls this tool repeatedly during one
   recording. Unbounded, it would eat the agent's own context window, which is a
   funny way to help it see.

   **Two things PR A must decide before it is implementable:**
   - a maximum dimension to downscale to, with `snitt_export`'s existing
     `maxSize` as the in-repo precedent for how that parameter should read;
   - what happens on a 5K or 6K display, stated rather than discovered.

   **The third is decided: the image is opt-in, not the default.** Returning
   pixels makes "screen content leaves this machine" the default rather than
   something the host separately chooses. Snitt itself still makes no network
   call, so the README's promise is untouched and this is orthogonal to §4.8's
   "does not upload", but the posture is not.

   `RecordingCoordinator.swift:354` already reasons about this exact
   sensitivity, and lands the other way:

   > an agent may only photograph the session it started. A human recording is
   > not readable over IPC, a screenshot of someone else's screen is the most
   > obviously sensitive thing this surface could hand out, and **§5's posture
   > makes that Snitt's problem rather than the caller's**.

   Shipping the bytes onward by default inverts that sentence. The consent
   machinery also does not cover it: `ConsentPolicy.evaluate` checks
   `agentRecordingEnabled`, `fullDisplayAllowed` and target presence, which
   authorise *recording*, never onward transmission of frame content.

   So: keep the path as the default, add an explicit per-call `inline` argument,
   and have the description say plainly that the image is embedded in the
   response and will be visible to whatever model drives the agent. That follows
   §5.6's existing precedent, where rendering captured input is opt-in and off
   by default. An agent that reads the description will pass `inline` when it
   needs to look, so the finding is still fixed; what changes is that the
   exposure is a documented choice rather than a silent one.

   Until the two open items are answered, **PR B is the one that can actually
   start**: small, fully specified, CI-gated.

2. **PR B: stop the silent wrong answers.** Route `subtitles` through
   `booleanValue()`; set `options.workingDirectory` on MCP start; thread
   `dropped` out of `Vocabulary.prepare` into the response. Small, and each is a
   correctness bug rather than a design change.
   **Structural guard, because this is the third round of the boolean bug:** a
   test that enumerates every boolean parameter on every tool and asserts a
   string `"true"` is refused, so the next parameter added cannot quietly repeat
   it.
3. **PR C: give the MCP server an output contract.** Every response gets
   `structuredContent` carrying the same object the CLI emits, keeping the prose
   text block. **Cheap:** the server is hand-rolled JSON-RPC, not an SDK, and a
   tool result is one dictionary literal at `snitt-mcp/main.swift:35`, so this is
   an added key rather than a dependency bump. Fixes the id-extraction tax and
   restores health and git to `snitt_inspect` in one move.
   Because no such contract exists in the spec, this PR also **writes one**: a
   new D-numbered decision stating what an MCP tool result must carry, and a
   snapshot test of the kind §15 already gives the CLI's JSON.
4. **PR D: the error taxonomy.** A machine-readable reason on argument errors,
   and split `internal_error` into at least "fix your request", "do not retry"
   and "retry shortly".
5. **PR E: coordinates.** Accept pixels or points where the agent has them
   (`snitt_crop`, `snitt_report_input`), and report the frame's pixel size early
   enough to be useful. This subsumes the demo plan's crop-in-points work.
6. **PR F: reach.** Expose `showSubtitles` and `showMarkers` (export
   configuration that happens to live in `edit.json`), and transcript read and
   write, so an agent can caption a demo without hand-editing JSON.

   **Why authored narration is in scope, against a review objection.** Review
   argued that letting an agent WRITE narration breaks §4.8's "scope is
   record-only", citing D100's in-editor `+` gesture as evidence it is a human
   feature. That misreads the constraint. **Record-only bounds what Snitt does
   to the world**, and the sentence says so: "It does not click, type, or
   navigate, and it does not upload." It is about Snitt not driving the UI, not
   about what may enter a recording.

   And the agent case is the stronger one, not the weaker one. A human narrates
   by speaking into a microphone. **An agent has no voice, so authored narration
   is its microphone**, the only way it can say something and have it land on
   the recording. D49 already grants agents "markers carrying a transcript", so
   agents speaking into recordings is established, not new. D100 records where
   the gesture was built, not that it is exclusive to the editor.
7. **PR G: naming and defaults.** Align `mark`/`add_marker` and
   `estimate`/`estimate_export`, default `clicks` to on when the bundle has
   reported input, document the three bare parameters.

8. **PR H: `snitt_list_recordings`.** Surface bundles left behind by capped or
   crashed sessions, so an agent can find its own debris. Small, and the
   watchdog that creates those bundles already exists.

9. **PR I: one call to tidy.** Fold bookend trimming into `snitt_auto_deep_trim`
   so "tidy the recording" is one call, not `snitt_trim` plus a second tool with
   an unrelated parameter vocabulary. Saves a round trip on every recording the
   loop produces.
10. **PR J: consent pre-flight.** Add grant state to `StatusInfo` so an agent can
   check before it calls, rather than learning by receiving `consent_required`.
11. **PR K: fix the loop's own instructions.** Step 5 says to crop private chrome
   away and never says to look first. Add the screenshot step, which only becomes
   truthful once PR A makes screenshots visible. Documentation only.

**Sequencing note.** PRs A through E are upstream of the README demo: the demo's
workarounds were symptoms of these gaps, which is how the audit started. #160,
#162 and #164 remain separately filed and unchanged by this.

## Decision log

Slug: `snitt-agent-api-audit`. Separate from the demo plan's log in the appendix.

| # | Decision | Rationale | Rests on | Status |
|---|---|---|---|---|
| A1 | The audit's scope is the MCP surface and the CLI, judged as one agent API | §4.8 defines them as two frontends over one core | §4.8 | Decided |
| A2 | ~~§4.8's output contract is breached by the MCP server~~ | Refuted: §15 scopes that contract to the CLI, and defines "cannot diverge" as shared `SnittAutomation` fixtures | A3 | Superseded |
| A3 | The real finding is a spec GAP: no output contract was ever written for MCP | MCP became the primary agent surface after the contract was written | §15 lines 1714-1716 | Decided |
| A4 | PR A leads on IMPORTANCE, not on sequence | It is the only item that changes what an agent can know; but review showed it is unspecified (no resolution policy), while PR B is small, specified and CI-gated | User pick, refined by review | Decided |
| A8 | PR A must state a max dimension and 5K/6K behaviour before it starts | An unbounded base64 PNG per call would consume the agent's own context, defeating the point | `ScreenshotWriter.swift:31`, no resize path | Decided |
| A9 | The inline image is opt-in; the path stays the default | Returning pixels makes "screen content leaves the machine" the default. `RecordingCoordinator.swift:354` already calls a screenshot "the most obviously sensitive thing this surface could hand out" and puts that on Snitt rather than the caller; consent covers recording, never onward transmission. §5.6's opt-in input rendering is the precedent | `RecordingCoordinator.swift:354`, `ConsentPolicy.evaluate`; confirmed by product owner 2026-09-18 | Decided |
| A5 | Agent-authored narration is IN scope | Record-only bounds what Snitt does to the world, not what enters a recording; an agent has no voice, so authored narration is its microphone; D49 already grants agents markers carrying a transcript | Product owner, 2026-09-18 | Decided |
| A6 | Every finding is verified against code read directly before this lands | Instructed after three reviewer claims proved wrong or misframed | User pick | Decided |
| A7 | `snitt_screenshot` returning a path is a defect, not a privacy design | No rationale is recorded anywhere; `ScreenshotWriter`'s comments concern testability and `CIContext` cost | `ScreenshotWriter.swift:18-29` | Decided |

### Corrections this audit made to itself

Recorded because three of them came from reviewers whose citations were real and
whose conclusions were not, and one was my own.

1. **§4.8 breach.** Mine. Refuted by §15's narrower scoping. Re-anchored as A3.
2. **Agent narration out of scope.** A reviewer's, citing D100. Refuted by the
   product owner: record-only constrains Snitt's actions, not a recording's
   contents.
3. **Caption band geometry** (demo plan). Two independent derivations, two
   different wrong answers, which is why that plan now measures rather than
   computes.
4. **Tracker membership as evidence** (demo plan). Circular: the issues were
   batch-filed nine seconds apart.

**shape: citation real, conclusion wrong.** Four instances across four passes.
The guard is A6: a reviewer's `file:line` is a place to look, never a fact.

---

# Appendix: the README demo plan

The demo plan that led here is represented below by its decision log. Its
detail (the shot list, the caption script and its authoring rules, the
production and export settings, the reproducible inputs) was written out in
full and can be restored on request; it is downstream of PRs A through E and
should be rewritten against the fixed API rather than the current one.

Two of its decisions are now superseded by this audit: D14/D15 (crop in points)
are subsumed by PR E, which covers both `snitt_crop` and `snitt_report_input`
rather than crop alone.

# Decision log

Slug: `snitt-readme-hero-demo`.

| # | Decision | Rationale | Rests on | Status |
|---|---|---|---|---|
| D1 | Hero is the full arc, not the transcript cut alone | A newcomer must learn "screen recorder" before "clever editor" | User pick | Decided |
| D2 | Backdrop is a narrated stumble over a plain low-motion window | Moves the information load onto the transcript, which is Snitt's own UI | User pick | Decided |
| D3 | GIF committed to the repo, not a GitHub-hosted mp4 | Renders on forks, mirrors and clones | User pick | Decided |
| D4 | Record-phase beat dropped | Snitt refuses a concurrent recording | `RecordingCoordinator.swift:269` | Decided |
| D5 | Captions from an agent-written authored transcript | `isAuthored` is designed for narration with no audio behind it | `Transcript.swift` | Decided |
| D6 | ~~Crop a dark band for the captions~~ | Superseded by D16: `OverlayPlacement` moves the captions instead of the frame growing around them | D16 | Superseded |
| D7 | Inner take uses recognised words, never authored | Deleting a word cuts the footage under it | `EditorWindowController.swift:1724` | Decided |
| D8 | Keep five cues; clip runs ~16s | No cue is then truncated by `trimOverlaps` | User pick | Decided |
| D9 | Export beat is a shell call, not the export sheet | Evidences the README's first claim; removes the sheet-capture unknown | User pick | Decided |
| D10 | Commit reproducible text inputs, not the bundles | Timing and geometry are expensive to recreate; footage is not | `.gitignore:51` | Decided |
| D11 | Version stamp now; CI check deferred to its own issue | README drift is wider than this asset | `README.md:11` | Decided |
| D12 | ~~Frame rate set explicitly gives a 10fps floor~~ | Superseded by D17: a chosen rate is a ceiling, not a floor | D17 | Superseded |
| D13 | Features land before the demo | Every workaround was a missing feature, and four were already filed | User pick | Decided |
| D14 | Crop takes points, converted via a recorded backing scale | Window bounds are reported in points | User pick | Decided |
| D15 | `--units pt` errors in one line when `backingScale` is absent | Assuming 1.0 silently crops a quarter of the region on Retina; a guard clause, not a subsystem | `RecordingMetadata` has no such field | Decided |
| D16 | #162 ships complete, but the gesture lands after the demo | Ships whole as chosen; the gesture is the harder half and the demo sets a value rather than dragging | User pick; #162 body | Decided |
| D17 | The 10fps floor is a verification check, not a feature | `SizeLadder` filters `$0 <= baseFPS`, so a chosen rate is a ceiling and the budget still wins | #164 issue body | Decided |
| D18 | `backingScale` derived per capture, as `pixelDimensions / frame` | Holds for window and display targets alike, and survives a window moved between displays | `CaptureSession.swift:118`, `CachedTargetResolver.swift:217` | Decided |
| D19 | The scale is a required initialiser parameter, not an optional | Four descriptor construction sites; the repo already shipped this exact omission bug with `processID` | `CachedTargetResolver.swift:160` comment | Decided |
| D20 | `OverlayPlacement` bumps `currentSchemaVersion` to 4, against #162's stated design | A dragged placement is an unrecoverable edit, crop's category, not a checkbox like `showClicks` | `EditDecisionList.swift:190,213` | Decided |
| D21 | PRs 3, 4 and 7 merge on a local `Scripts/run-tests.sh`, not on green CI | Their targets hang headless and are verified locally only | `field-notes.md:449` | Decided |
| D22 | Tracker membership is not evidence; the decision behind an issue is | #160/#162/#164 were batch-filed nine seconds apart, so their tracker age proves nothing | `gh issue view` createdAt | Decided |
| D23 | PR 2 is points-only: no error taxonomy, no migration, no hand-supplied scale | Smallest surface that makes the demo's crop honest | User pick | Decided |
| D24 | Features first stands, over shipping a rough demo now | The band workaround could not be derived at all, so the cheap path is not cheap | User pick | Decided |

## Recurrence (2026-09-18)

**shape: hand-derived constant asserted from reading code.** Three instances in
one review: the `estimate-export` verb (does not exist), the `maximumWidth`
citation (wrong file), and the caption-band geometry (wrong in two different
directions across two independent derivations).

Three hits is past patching instances. **Structural guard: this plan no longer
asserts derived pixel geometry.** PR 2 and PR 3 exist precisely so the numbers
come from the product rather than from arithmetic in a document.

---

*Refinement closed after four passes (13 persona reviews) on the product owner's
call. Two axes were never examined and are the first place a later pass should
look: concurrency (two agents, or an agent and a human recording at once) and
observability (whether `AuditRecord` can show that any of these fixes worked).*
