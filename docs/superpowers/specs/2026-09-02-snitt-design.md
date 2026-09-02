# Snitt — Design Spec

**Date:** 2026-09-02
**Status:** Approved for planning · hardened by one `plan-refinement` pass (2026-09-02)
**Author:** Ian (with Claude)

## 1. Overview

Snitt is a native macOS app for capturing screen, window, or application
recordings with microphone and system audio, applying basic cuts, and sharing
the result quickly. It is usable both by a person at the keyboard and by a
coding agent over a scripting interface.

The name is Swedish/Norwegian for *cut* (also *cross-section*), echoing the
German *Schnitt*, the standard term for a film edit.

**Target user:** product development teams and professionals — engineers, PMs,
designers, support — who need to record a demo or a repro and get it into
Slack, Discord, or a link within a minute or two. Increasingly, the "user" is
an agent working on that team's behalf: Claude Code or Codex recording a demo
of a feature it just built, to attach to a pull request.

The design goal that governs every trade-off below: **the time from "I want to
show someone this" to "they can watch it" must be short.** Where a feature and
that goal conflict, the feature loses.

**This has a budget, not just a slogan.** A first-run user must reach a
completed recording within **60 seconds of first launch**, granting exactly one
permission (Screen Recording). Every additional gate is measured against that
number. Snitt competes with `Cmd+Shift+5`, which is free, pre-installed, and
requires no setup at all; a permission wall spends the entire advantage before
the user has seen anything.

## 2. Goals

- Capture a display, a window, or an application, at high quality
- Capture microphone and system audio as **separate** tracks
- Trim, cut interior ranges (ripple delete), and mute/adjust audio tracks
- Export and share with minimal friction, including to a byte-size target
- **Be drivable by a coding agent**, safely and without permission friction
- **Start and stop from a single keystroke**, without opening a window (§4.11)
- **Cost exactly one permission dialog on first run** (§4.10)
- **Land on the clipboard by default**, so sharing is a paste (§4.1)
- **Tell an agent whether the recording actually worked** (§12.1)
- Feel like a native Mac app: fast, small, quiet, keyboard-driven

**Deferred past v0, deliberately:** rendering click and keystroke overlays. The
*event data* is still captured from M3 onward (see §4.2) — only the rendering is
deferred, because the renderer is the project's most expensive component and its
value is unproven (§4.5, §13).

## 3. Non-goals (v1)

Explicitly deferred, and none of these should be designed around now:

- **Hosted share links and accounts.** v1 is local-only. See §4.1.
- **Uploading exported files anywhere.** Snitt's contract ends at a local file
  path. An agent that wants a video in a pull request or a Slack thread uses its
  own mechanism (`gh`, the Slack API, a browser tool). This is stated explicitly
  because §1's framing could otherwise be read as a promise Snitt does not keep.
- **Agent-driven UI interaction.** Snitt records; it does not click or type.
- **Webcam / camera bubble.** No second video track in v1.
- **Zoom/pan keyframes** (Screen Studio-style cursor-follow animation).
- **Auto-removal of silence.**
- **Transitions, titles, captions, multi-clip assembly.** Snitt cuts one
  recording; it is not an NLE.
- **iOS/iPadOS capture, Windows, web.**
- **Burning overlays into `capture.mov` at record time.** This will be proposed
  as a cheap substitute for the deferred compositor. It is not one: it destroys
  the immutable-capture invariant (§7), breaks the one-builder guarantee (§9),
  makes overlays permanently un-toggleable, and returns GPU work to the capture
  path where dropped frames are least affordable (§4.5). Recorded as an
  anti-goal because the shortcut looks attractive precisely when the schedule
  is under pressure.
- **Blur / redaction of on-screen content — deferred, and bound to the M5 gate.**
  It is a second custom-compositor-class feature with no cheap shortcut, for the
  same reason overlays have none (§9, V5). §5's privacy framing makes this a
  near-certain request once agent recording ships; it must be decided *together*
  with the overlay gate (§13), never built reactively after a privacy scare and
  outside the gate discipline the rest of this plan follows.
- **Batch multi-format export** (mp4 + gif from one pass). Deferred as a
  post-gate candidate; its interaction with per-format `--max-size` iteration
  needs its own design pass.

## 4. Decisions

Rationale is recorded so these are not silently re-litigated. Claims marked with
a **V-tag** were verified against Apple's documentation; see the decision log.

### 4.1 Sharing: local-only, no destination abstraction

v0 and v1 export to disk and to the clipboard; the user drags or pastes into
Slack or Discord, which handle upload and playback themselves.

**Copying is the default outcome of stopping, not a subsequent step.** When a
recording stops, the export is placed on the clipboard automatically (opt-out in
settings). The distance from "the file exists on disk" to "it is pasted in
Slack" is where the §1 clock is actually lost — an export dialog and a trip
through Finder cost more than the recording did.

Hosted `snitt.app/x/abc123` links are a *second product* — storage, auth,
billing, retention, moderation, abuse — and bundling them in would delay the app
by months.

**No `ShareDestination` protocol.** Local-file save and clipboard copy are two
plain functions. An interface generalizing over two conformances, one of which
barely needs one, is an abstraction bought for a consumer that does not exist.
If a hosted destination is ever funded, introducing the protocol at that point
is a small, mechanical refactor against real requirements rather than guessed
ones.

### 4.2 Capture scope: screen + mic + system audio; input events logged, not yet drawn

No camera. System audio is included because demoing a product with sound is a
core use case and its absence would be immediately disqualifying.

Click and keystroke **events are logged** to a sidecar file from M3. **Rendering
them as overlays is deferred** past v0 and gated on evidence (§13). The split is
possible only because of the sidecar architecture (§4.5): events recorded today
can be drawn by a renderer written a year from now, against recordings made
before it existed. Logging is nearly free; rendering is the single most expensive
thing in the plan.

### 4.3 Distribution: direct download first, Mac App Store later

Direct distribution (Developer ID, notarization, Sparkle updates, third-party
licensing) ships first and avoids fighting the sandbox over global input
monitoring.

A Mac App Store build follows, with input monitoring disabled. **This is handled
by ordinary conditionals at the two or three call sites that need them, not by a
`BuildCapabilities` flag-set consulted everywhere.** Spike S1 determines how many
sites that actually is; if the answer turns out to be large, revisit. The
degraded behavior itself is a hard requirement either way (§11) — what was cut is
the abstraction, not the behavior.

### 4.4 Edit scope: trim, cut, track mute

Head/tail trim, interior ripple delete, per-track mute and gain, scrub and
preview. Enough for the overwhelming majority of demo recordings, consistent
with the speed goal in §1.

### 4.5 Pipeline: pristine capture, non-destructive edit, overlays as sidecar data

**Chosen over** burning overlays into frames at capture time, and over a custom
Metal frame-store engine.

The capture is written once and never mutated. Clicks and keystrokes are logged
as timestamped data, not drawn into the video. Editing mutates only an edit
decision list. Overlays, when built, are drawn at render time by a custom video
compositor.

The consequence is that almost everything stays reversible after recording
stops: toggle keystrokes off, restyle the click ripples, mute the mic, re-cut,
re-export — with no re-recording. Burn-in is cheaper to build but spends the
savings the first time a user wants overlays off in one video and on in
another, and it puts GPU compositing work in the capture path, which is when
dropped frames are least affordable.

The cost is a custom `AVVideoCompositing` implementation — the most technically
demanding component in the project, and the one most likely to slip. It is
nonetheless the *only* mechanism that satisfies §9: a custom compositor class is
invoked by AVFoundation both during `AVPlayerItem` playback and during offline
export **(V6)**, so preview and export run one implementation rather than two
that can drift. Because of that cost and its unproven value, the compositor is
**deferred behind a validation gate** (§13) — the mechanism is settled; the
timing is evidence-driven.

### 4.6 Minimum OS: macOS 15 (Sequoia)

ScreenCaptureKit captures the microphone natively from macOS 15 via
`SCStreamConfiguration.captureMicrophone`, delivering it through the *same*
`SCStream` as `SCStreamOutputType.microphone` **(V3)**. System audio has been
available since 13.0 **(V2)** and `SCContentSharingPicker` since 14.0 **(V1)**.

Targeting 15 means all three inputs arrive on one stream against one clock, and
the A/V drift problem **disappears entirely** rather than being mitigated. That
deletes a hand-synchronization code path, a fallback branch, a whole class of
late-discovered bugs, and one of the three gating spikes.

The cost is real and accepted: macOS 14 users are excluded. The judgment is that
a solo-scale project should not carry a permanent synchronization burden and a
version-conditional capture pipeline to serve one trailing OS release.

### 4.7 UI framework: SwiftUI shell, AppKit timeline and preview

SwiftUI for the app shell, menu bar, picker flow, and settings. AppKit via
`NSViewRepresentable` for the timeline and the video preview.

SwiftUI's gesture and layout model fights frame-accurate scrubbing and
drag-to-trim, and the preview requires an `AVPlayerLayer` regardless. Mixed is
the correct architecture here, not a compromise.

### 4.8 Agent automation: record-only, via CLI and MCP over one core

Coding agents must be able to produce a screen recording as part of their work —
most obviously, demoing a feature they just built.

**Scope is record-only.** Snitt starts, stops, trims, and exports. It does not
click, type, or navigate, and it does not upload (§3). The agent already has
tools for driving a UI and for attaching files; Snitt wraps a recording around
work the agent is already doing.

**Two frontends, one core.** A `snitt` CLI for universal access (any agent, any
shell, CI) and a bundled MCP server for agents that speak MCP natively. Both are
thin wrappers over a single `SnittAutomation` module — the same core the GUI uses
— so their behavior cannot diverge.

**Agent-facing output contract:** structured JSON on stdout, human-readable text
on stderr, meaningful exit codes.

### 4.9 Permissions: the CLI is a thin client, not a capturer

The CLI **must not call ScreenCaptureKit directly.** macOS TCC attributes a
capability to the *responsible process* — a chain that resolves up the process
tree to the originating GUI application — and child processes inherit their
parent's `p_responsible_pid` **(V4)**. A CLI capturing directly would therefore
attribute every permission prompt to whatever launched it (Claude Code's
terminal, Codex's sandbox, a CI runner), and each new parent would re-prompt.
Worse, an unbundled plain executable does not appear correctly in System
Settings' Screen Recording list at all, so the user would have no reliable way
to grant it.

Instead, both frontends are thin clients that talk over a local socket to the
resident Snitt.app, which holds the single TCC grant and performs all capture:

```
agent → snitt CLI ──┐
                    ├─ local socket → Snitt.app → ScreenCaptureKit
agent → MCP server ─┘                 (holds the TCC grant)
```

The CLI launches the app if it is not already running. One grant, prompted once,
in a context the user understands. A necessary side effect is that the app is
always resident during an agent recording, which is what makes the consent
guarantees in §5 enforceable.

### 4.10 Progressive permissioning — one dialog on first run

macOS TCC dialogs are system-owned and per-service. **They cannot be merged**;
there is no API for a combined prompt. The number of dialogs a user sees is
therefore decided entirely by how many services Snitt asks for, and when.

**System audio does not need its own permission.** On macOS 15 it is covered by
the Screen Recording grant — the settings pane is named "Screen & System Audio
Recording". So the core demo case, screen plus application sound, costs exactly
one dialog. This is a load-bearing fact: it means the default configuration is
also the cheapest one.

The resulting ladder, which no feature may shortcut:

| What the user does | Dialogs | Service |
|---|---|---|
| Record screen with system audio | **1** | Screen Recording |
| …plus voiceover | 2 | + Microphone |
| …plus keystroke overlays | 3 | + Input Monitoring |

Rules that produce that ladder:

1. **Microphone capture is OFF by default.** Most demos do not need voiceover,
   and defaulting it on turns every first run into two dialogs instead of one.
   The mic prompt is paid only when a user deliberately enables the mic.
2. **Nothing is requested at launch.** Each permission is requested at first use
   of the feature that needs it: Screen Recording at the first recording
   (unavoidable — it is the product), Microphone when mic capture is enabled,
   Input Monitoring only if overlay capture ships (§4.2, and see S1's finding
   that this requires `CGEventTap`, not `NSEvent`).
3. **Pre-explain before prompting.** Snitt shows its own brief sheet — what it
   needs, why, and that macOS will ask next — *before* triggering the system
   dialog. A prompt the user is expecting reads as normal software; one that
   appears unannounced reads as an app grabbing at their machine. This costs
   nothing and is the difference between "scary" and "fine".
4. **Handle the already-denied case explicitly.** macOS shows each dialog at
   most once per responsible process; after a denial, requesting again silently
   does nothing. The UI must detect denial and deep-link to the relevant System
   Settings pane instead of calling a request API that no-ops. Spike S1 proved
   how easily this is missed — a probe that only preflighted never prompted at
   all, and the failure was silent.

A first-run user therefore meets exactly one permission gate, which is what §1's
60-second budget requires. Requesting all three at launch is the single easiest
way to lose a user who is one keystroke away from pressing `Cmd+Shift+5`
instead.

### 4.11 Instant capture

Recording starts and stops from a **global hotkey** and a **menu-bar item**,
without opening a window. The target defaults to the last-used window or the
frontmost application; the picker is available but never on the critical path.

This is not a convenience feature. Snitt competes with `Cmd+Shift+5`, which is
free, pre-installed, and one keystroke away. A recorder that must be launched,
focused, and clicked through before it records has already lost the comparison
the §1 clock describes, no matter how good the rest of the app is. The status
item required by §5 for agent-session safety is the same component, so this
costs little beyond what consent already mandates.

### 4.12 Markers

A hotkey (human) or `snitt record mark` (agent) drops a timestamped, optionally
labeled bookmark into `events.json` while recording. Markers surface twice:

- as **jump points in the trim UI**, so cutting is "jump to marker, cut" rather
  than scrub-and-guess — the trim step, not the recording step, is where quick
  recorders lose time on longer takes;
- as an exported **WebVTT chapter sidecar**, so a reviewer can scrub a
  three-minute demo instead of watching it linearly.

The agent case is the stronger one: an agent narrates its own actions in text
far better than a human watching cold can reconstruct them, and today that
narration has nowhere to attach. This rides the existing sidecar architecture
exactly — another timestamped event type in a file that already exists — and
touches no video pixels, so it is available before the compositor.

## 5. Consent and privacy for agent recordings

An agent that can record the screen is a materially different privacy surface
from a recorder a human drives, and Snitt's users are precisely the people with
customer data, staging credentials, and private conversations on screen. These
are requirements, not settings suggestions:

- **Agent-initiated recording is off by default**, behind an explicit opt-in in
  settings.
- **Agent recordings are window-scoped by default**, never full-display. The
  common leak is incidental — a notification banner, a password manager, an
  adjacent Slack thread — and window scoping makes the safe thing the default
  thing.
- **A visible indicator is shown for the entire duration** of any
  agent-initiated session, with a menu-bar kill switch that stops it
  immediately.
- **Agent sessions have a maximum duration**, so a hung or abandoned agent
  cannot fill the disk with a six-hour recording.

**These requirements bind the schedule, not just the code.** Agent recording
ships in M2, so the menu-bar indicator and kill switch ship in M2 — as a minimal
status-item shell, with no editor and no timeline. A safety guarantee whose
enforcement mechanism is scheduled three milestones later is not a guarantee.

## 6. Architecture

Swift package targets, each testable without launching the app:

| Module | Responsibility | Depends on |
|---|---|---|
| `SnittCapture` | One `SCStream` → video, system audio, mic → `AVAssetWriter` | — |
| `SnittEvents` | Global click/keystroke monitoring → timestamped log | — |
| `SnittDocument` | `.snitt` bundle read/write, crash recovery | — |
| `SnittEdit` | Edit decision list and time math | `SnittDocument` |
| `SnittRender` | `AVMutableComposition` builder; custom `AVVideoCompositing` (deferred, §13) | `SnittEdit`, `SnittEvents` |
| `SnittExport` | Encode presets, size targeting, progress | `SnittRender` |
| `SnittAutomation` | Session control, target enumeration, consent enforcement, IPC server | `SnittCapture`, `SnittEdit`, `SnittExport` |
| `SnittDiagnostics` | Structured logging, session audit, diagnostics bundle | — |
| `SnittUI` | SwiftUI shell, status item, AppKit timeline and preview | all |
| `snitt-cli` | Thin CLI frontend over the IPC protocol | `SnittAutomation` |
| `snitt-mcp` | Thin MCP server frontend over the IPC protocol | `SnittAutomation` |

The GUI is one frontend among three, not the app itself.

## 7. The `.snitt` document

Recordings are a **package directory**, not a flat file:

```
MyDemo.snitt/
  capture.mov      video track + 2 discrete audio tracks (mic, system)
  events.json      timestamped click/keystroke log + markers (§4.12)
  edit.json        EDL: cuts, per-track mute/gain, overlay settings
  meta.json        capture health (§12.1), git context, session provenance
  poster.png       thumbnail
```

`meta.json` carries what a machine needs to reason about the recording without
decoding it: capture health metrics, the git branch/commit/PR the recording was
made against when one is discoverable, and whether the session was human- or
agent-initiated. When Snitt records from inside a repository, that context is
also reflected in the bundle name, so a demo arrives as
`feature-branch-a1b2c3.snitt` rather than `Screen Recording 2026-09-02.mov`.

Because `capture.mov` is immutable and `edit.json` is the only thing editing
touches, the format gives undo, crash recovery, re-export at new settings, and
later restyling of old recordings — without any of those being features built
separately. It is also what allows §4.2's split: `events.json` is captured now
and rendered whenever the compositor eventually exists.

## 8. Automation API

CLI surface; MCP tools mirror these one-to-one
(`snitt_list_targets`, `snitt_start_recording`, …):

```
snitt targets list                          → JSON: displays, windows, apps
snitt record start --window-id N [--mic] [--system-audio]
                   [--max-duration 300]     → session id
snitt record mark <session> [--label "..."] → timestamped marker (§4.12)
snitt record stop <session>                 → bundle path + health report
snitt inspect <bundle>                      → JSON metadata, no GUI
snitt trim <bundle> --start T --end T       → headless EDL edit
snitt trim <bundle> --auto-trim             → clip dead air (see below)
snitt export <bundle> --format mp4|gif --out PATH
                      [--scale 0.5] [--max-size 10MB] [--chapters]
                                            → writes file + manifest JSON
snitt diagnostics export --out PATH         → support bundle
snitt record --app Safari --duration 30 --out demo.mp4   # one-shot
```

`--max-size` iterates encoder settings to land under a byte target. Agents
attaching demos to pull requests hit host file-size limits constantly, and size
targeting needs neither the EDL nor the compositor — only bitrate and scale
iteration over the encode. **It therefore ships with M2**, alongside the
automation surface it exists to serve, rather than trailing it by four
milestones.

**`snitt inspect` and the export manifest** exist because an agent cannot watch
the video it just made. `inspect` reports duration, tracks, resolution, event and
marker counts, and health (§12.1) without launching a GUI or decoding the movie;
the export manifest adds byte size, whether `--max-size` was met, and the chapter
list. Together they let an agent write something *factually true* in a pull
request — "42s demo, 3.1 MB, chapters: repro / fix / verify" — instead of
narrating a video it has never seen. Both are near-free: every value is already
computed elsewhere in the pipeline.

**`--auto-trim`** clips dead air before the first and after the last logged input
event. Note the limit honestly: it works only where input events exist. An agent
that drives an app through a CLI, an HTTP call, or a programmatic API produces no
OS-level input at all, so there is nothing to key on — this is primarily a
human-recording feature, and spike S1's findings on event capture determine how
far it generalizes. It is **not** the silence-removal that §3 excludes: that is
audio-signal analysis, this is a query over an event log already on disk.

The contract ends at a local path. Snitt does not upload (§3).

## 9. Data flow

**Record.** A single `SCStream` delivers all three inputs — video, system audio,
and microphone — as distinct `SCStreamOutputType` values against one clock
**(V3)**, feeding one `AVAssetWriter` with three inputs. There is no separate
mic capture path and no hand-synchronization. `SnittEvents` appends to
`events.json` in parallel. Writing is incremental, so a crash leaves a playable
file rather than nothing.

Agent-initiated recordings enter the same path through `SnittAutomation`, which
enforces §5 before starting a session. There is one capture implementation; the
caller only determines who asked and which consent rules apply.

**Edit.** Stopping opens the editor with a default EDL spanning the full range.
All edits mutate the EDL only. Headless `snitt trim` mutates the same EDL through
the same model code, with no UI involved.

**Preview and export share one builder.** Both construct the same
`AVMutableComposition` and `AVVideoComposition` from the EDL. Preview attaches it
to an `AVPlayer`; export hands it to an `AVAssetWriter`.

This sharing is deliberate and load-bearing. The most common serious bug class
in video editors is an export that does not match the preview, and the only
durable defense is making the two literally the same code path.

Two constraints follow, and both are binding:

1. **Until the compositor exists, preview and export use an explicit passthrough
   `AVVideoComposition` slot** — not an implicit `nil` scattered through call
   sites. When overlays ship, the *only* change is constructing a non-nil
   `AVVideoComposition(customVideoCompositorClass:)` and assigning it to the same
   `AVPlayerItem` and export call sites. This is what makes the deferral in §13
   cleanly additive rather than a rewrite.
2. **`AVVideoCompositionCoreAnimationTool` (`animationTool:`) is not an option
   and was never in scope.** It cannot be used with `AVPlayerItem` — it is
   offline/export only, with `AVSynchronizedLayer` as its playback counterpart
   **(V5)** — so adopting it would mean two overlay implementations that can
   diverge, defeating the guarantee this section exists to make. Recorded here
   because it is the obvious-looking shortcut and will otherwise be re-proposed.

## 10. IPC protocol and version skew

Sparkle can update Snitt.app while an agent still holds a cached, older `snitt`
CLI or MCP server. The frontends and the app are separately updatable artifacts,
so they need an explicit compatibility contract:

- **Every connection begins with a version handshake** exchanging app version and
  IPC protocol version.
- **On incompatibility the frontend refuses to proceed**, emitting a structured
  `{"error": "upgrade_required", ...}` on stdout with a non-zero exit code. It
  never silently misparses a newer protocol, and it never partially executes.
- **`snitt --version` reports both** the CLI and the resident app version, so a
  support thread can identify skew in one command.

## 11. Error handling

**Permissions are independent, individually recoverable gates**, requested
progressively (§4.10). Each has its own explanatory state and a deep link to the
relevant System Settings pane. Denying Input Monitoring must degrade to "no
overlay capture" and never block launch or recording — this is also the seam the
Mac App Store build uses (§4.3).

Other failure modes:

- **Disk full mid-recording:** finalize the partial file; never discard it.
- **Display disconnected or captured window closed:** stop the stream and
  finalize cleanly.
- **Unfinalized bundle found at launch:** offer recovery.
- **Agent requests capture while permission is missing:** fail with a structured,
  actionable error on stdout and a non-zero exit code. Never block on a GUI
  prompt an agent cannot see or answer.
- **Agent session orphaned by a crashed client:** the max-duration cap (§5)
  bounds it; the app finalizes and releases the session.
- **IPC version mismatch:** see §10.
- **Compositor render failure mid-export** (once overlays ship): detect it and
  re-export with overlays forcibly disabled, surfacing a warning. Emitting a
  black or corrupt video is the worst possible outcome — a usable video without
  overlays is strictly better than a broken one with them.

## 12. Logging and diagnostics

Snitt is a resident background process with a headless automation surface. When
a user or an agent reports "the recording is broken," there must be something to
look at.

- **Structured `os_log` logging per module**, with a subsystem per target.
- **`snitt diagnostics export`** bundles recent logs, app and CLI versions,
  permission states, and recent session metadata into a single file for support.
- **Opt-in crash reporting**, surfaced in settings.
- **Every agent-initiated session is audit-logged** — session id, target,
  duration, initiator, outcome — so an agent-side incident can be reconstructed
  even though no human watched it happen. This serves §5 as much as it serves
  support.
- **Error categories are distinguishable** in logs: permission fault vs disk
  fault vs compositor fault. "It failed" is not a diagnosable report.

### 12.1 Capture health verification

`snitt record stop` returns cheap health metrics alongside the bundle path:
sampled frame variance (to catch black, frozen, or occluded capture) and audio
RMS per track (to catch a silent mic or unrouted system audio).

This exists because **an agent is blind to its own output.** Today a recording of
the wrong window, an occluded surface, or a dead microphone returns a valid path
and exit code 0, and the agent attaches a black or silent video to a pull request
with complete confidence. §11 already holds that emitting a black or corrupt
video is the worst possible outcome — that principle applies with more force to
capture itself, which currently has no check at all, than to the compositor
failure it was written for.

Health metrics are **warnings, not failures**: a legitimately static UI demo will
trip low frame variance, so the threshold must be tuned against real recordings
before it is allowed to gate anything. Sampling happens during the existing
`AVAssetWriter` pass; there is no second decode.

## 13. Milestones

- **M0** Spikes S1, S3 (§14)
- **M1** Capture to disk — one `SCStream`, video + system audio + mic
- **M2** `SnittAutomation`, IPC + version handshake, CLI, MCP server, consent
  model (§5), **menu-bar status item + kill switch**, global hotkey instant
  capture (§4.11), export with `--max-size`, stop-and-copy default (§4.1),
  `snitt inspect` + export manifest, capture health (§12.1), git context (§7)
- **M3** Event logging (data only, no rendering), markers + WebVTT chapters
  (§4.12), `--auto-trim`, progressive permission onboarding (§4.10) — including
  the pre-explain sheet and the already-denied deep link, which are the parts
  most likely to be skipped and are what make the flow feel safe rather than
  grabby
- **M4** EDL model, timeline UI with marker jump-points, preview (explicit
  passthrough composition slot, §9)
- **M5** Packaging: Developer ID, notarization, Sparkle, diagnostics (§12)
- **▶ v0 SHIP — validation gate**
- **M6** Overlay desirability probe
- **M7** Custom compositor + overlay rendering *(conditional on M6)*
- **M8** Licensing; Mac App Store variant

### The v0 gate

v0 is **record + trim + export + agent automation, with no overlay rendering**.
It ships to 5-10 target users before the most expensive component is built.

**Validation must target the right question.** Without overlays, v0's
differentiation from free built-in `Cmd+Shift+5` recording is precisely two
things: the non-destructive trim/export loop, and the agent surface. So the
questions are:

1. Does anyone choose Snitt over `Cmd+Shift+5` for the record → trim → share
   loop?
2. Does an agent actually record with Snitt and attach the result to a PR?

Not "does anyone use this." If v0 fails those two questions, a compositor will
not save it, and building it first would have been the most expensive possible
way to learn that.

**M6 is a probe, not a build.** Overlay desirability is tested with a throwaway
mockup or a faked demo video shown to those same users — cheap, non-shipping,
and consistent with §14's spike philosophy. This exists so that "deferred" does
not silently become "no evidence either way until someone builds it." Build
order and validation signal are separate questions; the plan must answer both.

## 14. Spikes (gating, throwaway)

Output is a written recommendation; any code is labeled throwaway.

**S1 — Keystroke monitoring API.** Can global keystroke capture use
`NSEvent.addGlobalMonitorForEvents`, or does it require `CGEventTap` with an
Input Monitoring grant? Determines the permission story, the App Store
feasibility of overlays, and how many call sites §4.3's conditionals touch.

**S3 — IPC-triggered capture.** Does ScreenCaptureKit capture correctly when
initiated over IPC from a background (non-foreground) app? Define and verify
behavior when the screen is locked, when no user is logged in, and when the app
was launched by the CLI rather than by the user.

*(S2 — A/V drift — was deleted. Raising the floor to macOS 15 (§4.6) removes the
hand-synchronized mic path the spike existed to de-risk. This is the clearest
win of the refinement pass: a scope decision that deleted a risk rather than
managing it.)*

## 15. Testing

- **EDL time math** — pure functions, heavy unit coverage. Ripple deletes,
  overlapping cuts, and frame-boundary rounding are where real bugs live.
- **Event lookup** — time-indexed overlay queries.
- **Compositor** (once built) — golden-frame tests: render at time *T*, compare
  to a reference PNG within tolerance. **Run on both Apple Silicon and Intel**;
  custom video compositing is a known source of hardware-specific bugs, and a
  single-architecture CI proves nothing about the other.
- **Capture** — behind a protocol seam so tests inject synthetic sample buffers
  rather than requiring a real screen.
- **Automation contract** — the CLI's JSON output and exit codes are a public
  interface with agents as consumers; they get snapshot tests. The MCP server and
  CLI are tested against the same `SnittAutomation` fixtures to prove they cannot
  diverge. The §10 version handshake gets explicit skew tests.
- **Consent rules** — §5 is enforced in `SnittAutomation` and unit-tested there,
  not left to UI behavior.
- **Permissions** — manual QA matrix; not meaningfully automatable.

## 16. Risks

| Risk | Mitigation |
|---|---|
| Custom compositor is the hardest component and could slip | Deferred behind the v0 gate (§13); mid-export fallback (§11); cross-architecture golden frames (§15) |
| v0 is not differentiated enough vs free built-in recording | That is exactly what the v0 gate tests, before the expensive build |
| Input Monitoring blocks the App Store plan | Spike S1; overlays degrade cleanly by design (§11) |
| Agent recording leaks sensitive on-screen content | §5 consent rules, enforced in `SnittAutomation` and unit-tested; audit log (§12) |
| TCC grant attribution breaks agent workflows | §4.9 thin-client architecture; spike S3 verifies it |
| CLI/app version skew corrupts agent workflows | §10 handshake; refuse rather than misparse |
| macOS 15 floor excludes users | Accepted trade (§4.6); revisit only if adoption data contradicts it |
| Scope creep toward a full NLE, or toward UI automation | §3 non-goals are explicit and load-bearing |
| The burn-in "shortcut" gets adopted under schedule pressure | Named as an explicit anti-goal in §3 with its consequences spelled out |
| Redaction gets built reactively after a privacy incident | Bound to the M5 gate decision in §3; same cost class as overlays |
| Capture health warnings fire on legitimately static demos | Warnings only, never gating; thresholds tuned against real recordings (§12.1) |
| Permission dialogs stack up and read as invasive | §4.10's ladder: mic off by default, nothing requested at launch, pre-explain before every prompt. First run costs one dialog |
| Incidental capture of notifications and private content | §5 window-scoping for agent sessions; observed in the first real M1 recording, where a Mail password notification was captured (see M1 verification record) |

## 17. Domains

`snitt.app` is the intended primary; `snitt.com` was already registered.
`getsnitt.com` is available as a redirect. Availability was inferred from DNS
records rather than registry lookups and must be reconfirmed at a registrar.
App Store name collisions and trademark status have **not** been checked.

---

## Decision log

Canonical cache for `plan-refinement` · slug: `snitt-design` · session: 8fd6e671
`conformance: 2026-09-02` (first run — cold start, no prior cache)

### Verified facts (Phase 2, 2026-09-02)

Grounded against Apple's documentation JSON API. No codebase exists yet, so
these are the ground truth available.

| ID | Claim | Status |
|---|---|---|
| V1 | `SCContentSharingPicker` is macOS 14.0+ | **CONFIRMED** — docs JSON `introducedAt: "14.0"` |
| V2 | `SCStreamConfiguration.capturesAudio` (system audio) is macOS 13.0+ | **CONFIRMED** — docs JSON `introducedAt: "13.0"` |
| V3 | `SCStreamConfiguration.captureMicrophone` is macOS **15.0+**; on 15+ the mic arrives through the same `SCStream` as `SCStreamOutputType.microphone`. On macOS 14, mic must be captured via `AVCaptureDevice` and hand-synchronized. | **CONFIRMED** — docs JSON `introducedAt: "15.0"`. (The enum *case* badge reads 12.3, inherited from the enum; the functional gate is the config property.) |
| V4 | macOS TCC attributes to the **responsible process**, which chains to the GUI app; children inherit `p_responsible_pid`; an unbundled plain executable does not appear properly in System Settings for screen capture. | **CONFIRMED** — Apple developer forums + TCC documentation. §4.9's *conclusion* is right; its stated mechanism ("per-binary") is imprecise. |
| V5 | `AVVideoCompositionCoreAnimationTool` cannot be used with `AVPlayerItem` — offline/export only; playback overlays require `AVSynchronizedLayer`. | **CONFIRMED** — Apple developer forums. Means overlays in both preview and export from one code path require a custom `AVVideoCompositing` class. |
| V6 | A custom `AVVideoCompositing` class **is** used for real-time playback: for an `AVPlayerItem` with non-nil `videoComposition` whose `customVideoCompositorClass` is set, AVFoundation instantiates and uses it. | **CONFIRMED** — Apple documentation. §9's one-builder mechanism is sound; the compositor is both necessary and sufficient. |

### Decisions

| # | Decision | Rationale | Rests on | Status | Shape |
|---|---|---|---|---|---|
| D1 | Run tier: full loop — 5 personas, max 2 passes, max 2 cross-exam rounds | User confirmed explicitly at Phase 0 | — | Decided | — |
| D2 | Consent mode: auto-accept reversible + CONFIRMED + non-scope fixes; all tradeoffs to menu | User confirmed at Phase 0 | — | Decided | — |
| D3 | `model-policy`: Opus main line, Sonnet personas | Judgment core on Opus; gathering on Sonnet | — | Decided | — |
| D4 | §4.9's TCC mechanism restated as "responsible process" rather than "per-binary" | Factual correction, one right answer; conclusion unchanged | V4 | Decided | unverified-platform-mechanism |
| D5 | §4.5's compositor rationale must drop the zoom/pan justification | It cites §3's own declared non-goal; the real justification (WYSIWYG parity, §9) was available and stronger | V5, §3, §9 | Decided | rationale-cites-non-goal |

### Recurring shape (Phase 5b)

**Class identified — `unverified-platform-capability`: platform/API behavior asserted
from memory and never checked against Apple's documentation.** Two instances this pass:
D4 (§4.9 described TCC as per-binary; it is responsible-process) and O2 (§9 specified
one unconditional mic pipeline, unaware that macOS 15 captures mic natively in-stream).
Ruled on the class, not the instances: **every platform capability claim in this spec
carries a verification tag in the log above.** A third instance escalates to a
structural guard rather than another patch.

### Rulings

| # | Item | Ruling | Carried by | Status |
|---|---|---|---|---|
| O1 | Overlay compositor sequencing | Keep custom `AVVideoCompositing` as the mechanism (V5+V6: necessary and sufficient); **defer it off the critical path**. Correct §4.5's rationale. M4 must ship preview with an explicit `videoComposition` slot so M5 is purely additive. | Unanimous after one cross-exam round: red team conceded and endorsed; pragmatist refined (separate build-order from validation-signal); product/UX refined (v0 must validate trim loop + agent surface, not "does anyone use this"); operator supported (removes a hard-to-diagnose GPU-class support burden); principal engineer refined the mechanism and confirmed low rework. | Decided |

### Applied this pass (auto-accept)

- **A1** §4.9 — TCC mechanism restated as *responsible process* + `p_responsible_pid`
  inheritance, plus the unbundled-executable consequence. (D4, CONFIRMED via V4.)
- **A2** §4.5 — struck the zoom/pan justification (it cited a §3 non-goal); replaced
  with the real one: only mechanism satisfying §9. (D5, CONFIRMED via V5+V6.)
- **A3** §9 — recorded that `animationTool:` is out of scope and why, so this review
  artifact does not recur. (CONFIRMED via V5.)

### Pass 1 — decisions applied (user-approved menu, 2026-09-02)

All eleven menu items were selected. Interactions between them were resolved as noted.

| # | Decision | Rationale | Rests on | Status | Shape |
|---|---|---|---|---|---|
| D6 | Defer the custom compositor behind a v0 validation gate; keep it as the mechanism | Highest-cost, highest-slip component with unproven value; sidecar architecture makes it cleanly additive | V5, V6; unanimous Phase 7 ruling | Decided | expensive-unvalidated-component |
| D7 | M4 preview must use an explicit passthrough `AVVideoComposition` slot | Makes D6's deferral additive rather than a rewrite; stated as a constraint, not an assumption | Principal engineer, cross-exam r1 | Decided | implicit-assumption-unstated |
| D8 | Cut `ShareDestination` protocol | Abstraction over two conformances for a consumer that does not exist | Red team R2 | Decided | speculative-generality |
| D9 | Cut `BuildCapabilities` flag set; use conditionals at real call sites | Same; S1 will size the actual number of sites. Degraded *behavior* retained as a requirement | Red team R2; §11 | Decided | speculative-generality |
| D10 | `--max-size` export ships with M2, not M6 | Needs neither EDL nor compositor; serves the agent use case it was written for | Pragmatist PRAG2; §13 | Decided | feature-trails-its-own-justification |
| D11 | **Raise minimum OS to macOS 15**; delete spike S2 | Native in-stream mic delivery removes A/V drift entirely rather than mitigating it; deletes a fallback path, a bug class, and a gating spike. Cost: excludes Sonoma users — accepted | V3; principal engineer PE1 | Decided | unverified-platform-capability |
| D12 | Menu-bar status item + kill switch ship in M2 | §5's safety guarantee cannot be enforced by UI scheduled three milestones later | Principal engineer PE2 | Decided | guarantee-without-enforcement |
| D13 | Add IPC version handshake; refuse on mismatch | App and frontends are separately updatable; silent misparse is the failure to prevent | Operator OP1 | Decided | separately-versioned-artifacts |
| D14 | Add logging, diagnostics bundle, crash reporting, agent session audit (§12) | Resident background process with a headless surface and nothing to inspect on failure | Operator OP2 | Decided | undiagnosable-by-construction |
| D15 | Compositor mid-export fallback + cross-architecture golden frames | A usable video without overlays beats a corrupt one with them; single-arch CI proves nothing about the other | Operator, cross-exam r1 | Decided | hardware-variable-rendering |
| D16 | Scope out uploading explicitly; add progressive permissioning + 60s time-to-first-recording budget; retarget v0 validation | §1 implied a loop nothing closed; three upfront gates contradict the north star; overlay-free v0 must validate the trim loop and agent surface specifically | Product/UX UX1+UX2, cross-exam r1 | Decided | promise-exceeds-delivery |

`conformance: 2026-09-02` — post-application walk clean: all 17 sections resolve,
every §-reference maps to a real section, and the only surviving mentions of
`ShareDestination`, `BuildCapabilities`, and S2 are the deliberate negations
explaining their removal.

### Pass 2 — features (generative pass, 2026-09-02)

Requested by the user: "consider additional features that would make this a
compelling product." Roster: product/UX, principal engineer, pragmatist, red team
(tasked as anti-scope-creep counterweight), plus a new agent-workflow specialist.
Operator sat out — production diagnosability is not a feature-ideation axis.

Red team pre-registered five admission criteria and five trap predictions before
seeing any proposal. **All five predicted traps went unproposed** (webcam bubble,
post-hoc annotations, captions, agent-only hosted links, multi-clip stitching) —
evidence the generative pass stayed inside its constraints rather than a claim
that it was well behaved. Its criteria were applied literally at triage.

12 raw proposals deduplicated to 8; all 10 menu items approved by the user.

| # | Decision | Rationale | Rests on | Status | Shape |
|---|---|---|---|---|---|
| D17 | Global hotkey + menu-bar instant capture (§4.11), M2 | Snitt loses the start-time race to `Cmd+Shift+5` without it; shares the status item §5 already mandates | Product/UX + pragmatist, independently | Decided | competes-with-free-default |
| D18 | Stop-and-copy is the default outcome of stopping (§4.1), M2 | The disk→Slack gap is where the §1 clock is lost, not the recording | Product/UX | Decided | value-lost-in-last-step |
| D19 | Markers + WebVTT chapters (§4.12), M3/M4 | Speeds trim for humans; gives an agent's narration somewhere to attach for reviewers | Product/UX + agent specialist (merged) | Decided | sidecar-pattern-reuse |
| D20 | Git context in `meta.json` + bundle name (§7), M2 | Sharpens the agent→PR story the v0 gate measures | Pragmatist | Decided | provenance-metadata |
| D21 | Capture health verification (§12.1), M2 | **An agent is blind to its own output**; today a black or silent recording returns exit 0 | Agent specialist | Decided | blind-producer |
| D22 | `snitt inspect` + export manifest (§8), M2 | Lets an agent state facts about a video it cannot watch, instead of guessing | Principal engineer + agent specialist (merged) | Decided | blind-producer |
| D23 | `--auto-trim` (§8), M3 — scoped honestly | Useful where input events exist; **rationale partly refuted** — agents driving via CLI/HTTP/API generate no OS input, so the "best for agents" claim does not hold. Kept as a human-recording feature pending S1 | Principal engineer; refuted in part by Decider | Decided | rationale-overreach |
| D24 | Burn-in of overlays at capture time → explicit **anti-goal** (§3) | Looks like a cheap substitute for the deferred compositor; actually destroys the immutable-capture invariant and the one-builder guarantee | Principal engineer (inverse finding) | Decided | attractive-shortcut-violates-invariant |
| D25 | Blur/redaction deferred and **bound to the M5 gate** (§3) | Second compositor-class feature with no cheap shortcut; must not be built reactively outside gate discipline | Pragmatist (trap warning) | Decided | second-instance-of-gated-cost |
| D26 | Batch multi-format export deferred post-gate (§3) | Real but weakest; `--max-size` interaction needs its own design pass | Principal engineer | Decided | underspecified-interaction |

**Dissent recorded (red team, `confidence: high`):** the correct answer to "make it
compelling" is to add *nothing* — v0 has never shipped, so every proposal is a
guess dressed as a feature, and the gate exists to replace guesses with
observation. The pragmatist partly concurred (only near-zero-cost items belong
before the gate). The user reviewed this dissent and elected to proceed. It is
preserved here because if v0's gate later shows these features did not move the
needle, this is the entry that predicted it.

`conformance: 2026-09-02` (pass 2)

### Post-M1 — decisions from real-recording review (2026-09-02)

| # | Decision | Rationale | Rests on | Status | Shape |
|---|---|---|---|---|---|
| D27 | Microphone capture defaults OFF; §4.10 rewritten around a one-dialog first run | macOS TCC dialogs cannot be merged, but system audio shares the Screen Recording grant on macOS 15, so screen + app sound costs exactly ONE dialog. Defaulting the mic on doubled that for every user, contradicting §1's 60-second budget. Verified in practice: `snitt-probe` was requesting mic unconditionally | Verified during M1 manual verification; §1, §4.10 | Decided | default-costs-a-permission |
| D28 | Pre-explain sheet required before every system prompt; already-denied case must deep-link to System Settings | A prompt the user expects reads as normal; an unannounced one reads as grabbing. And macOS never re-prompts after denial — a request call silently no-ops, which is exactly how spike S1 wasted two runs before the defect was found | S1 findings; §4.10 | Decided | silent-no-op-permission-api |

`conformance: 2026-09-02` (post-M1)

### Termination

**Condition 1 — converged.** The single contested item settled in one
cross-examination round (budget allowed two); the remaining seven Important items
were uncontested and recorded directly; the conformance walk is clean.

**Verdict: Proceed.** Next step is `superpowers:writing-plans` against §13.

Not covered by this pass, by design: adversarial review of code (none exists
yet — that belongs to `/code-review` once the plan produces a diff), and a
zero-trust plan-vs-implementation audit. This was the light, memory-carrying pass.
