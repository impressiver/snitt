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
- **Cost exactly one permission dialog on first run, and not ask again** (§4.10, §5.2)
- **Record a window by default**, never the whole screen by accident (§5.1)
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
- **A persistent per-application agent grant store.** Specified, then deleted —
  it could not deliver the frictionless recording it existed for. See §5.4 for
  the full reasoning, recorded so it is not re-proposed.

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

**D56 expands this**, in two tiers that are deliberately separated because only
the second changes what an edit *is*:

**Tier 1 — a richer editor over the same model.** The timeline represents
**output** duration, so a cut shortens it. **Selection is independent of cutting**:
selecting a span is UI state, and a cut is an operation applied to one (selection
renders transparent blue). A cut collapses to a **red line — a fold, not a gap**,
with the two edges touching; clicking expands it to show the folded segment on a
transparent red ground, and an expanded cut still contributes **nothing** to
duration and is still skipped during playback. Right-clicking offers removal,
restoring the segment. **Cuts are therefore reversible objects with identity**,
which `TimeRange` does not currently have. Audio and video render as separate
tracks, cuts synchronised across them by default. Markers get their own thinner
track above, and become **moveable and editable**, carrying the metadata D50's
transcripts need.

**Tier 2 — a different editing model, and priced as such.** Unlocking
audio/video sync makes `cuts` **per-track** rather than one global list, which
changes the `.snitt` format (§7) and `snitt trim`'s semantics. **Slice** cuts at
a point to permit **reordering segments** — and that is the one that reaches
furthest: today the EDL means "the source, minus these ranges," so order is
implicit and monotonic. Reordering makes it an **ordered sequence of segments**,
which is a real NLE model and changes `CompositionBuilder`, `TimeRangeMapping`,
`MarkerMapping`, export, and §9's data flow. Marker remapping stops being
monotonic, which is the assumption `MarkerMapping` is built on.

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
**parked** (§13) — the mechanism is settled; the timing is not. D64 later
removed most of its workload: crop and zoom are layer-instruction transforms, so
a custom compositor is now needed only for position-critical *drawn* overlays.

### 4.6 Minimum OS: macOS 15 (Sequoia)

ScreenCaptureKit captures the microphone natively from macOS 15 via
`SCStreamConfiguration.captureMicrophone`, delivering it through the *same*
`SCStream` as `SCStreamOutputType.microphone` **(V3)**. System audio has been
available since 13.0 **(V2)** and `SCContentSharingPicker` since 14.0 **(V1)**.

`SCContentSharingPicker` matters for a second reason discovered after M1: macOS
15 shows a **recurring monthly re-consent prompt** to apps that bypass the system
picker and enumerate content themselves. Using the picker is therefore not just a
UI convenience — it is what makes the Screen Recording grant a one-time event
rather than a monthly interruption (§5.2).

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

**But recording alone does not produce a good demo, so Snitt coordinates** (D49):
the agent drives the UI with its own tools while Snitt supplies what those tools
cannot — **pause/resume** so deliberation is not filmed as dead air,
**screenshot** so the agent can see the state of the window it is recording, and
**markers carrying a transcript** so it can narrate what it is demonstrating.

That split is a **provisional** decision, not a settled boundary. Its cost is
that synthetic input is not on the recording clock, so a click and the marker
describing it correlate only as well as the agent's own timing. If demos come
out poor for that reason, D49 says so explicitly and names it as grounds to
reopen.

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

**One dialog, once.** The ladder above counts first-run dialogs; §5.2 is what
stops that one dialog from recurring. An app that bypasses the system picker is
re-prompted monthly by macOS 15 regardless of how few services it requested, so
progressive permissioning and picker-based selection are two halves of the same
promise. Neither alone delivers it.

A first-run user therefore meets exactly one permission gate, which is what §1's
60-second budget requires. Requesting all three at launch is the single easiest
way to lose a user who is one keystroke away from pressing `Cmd+Shift+5`
instead.

### 4.11 Instant capture

Recording **starts** from a **global hotkey** and a **menu-bar item** without
opening a window. **Every press presents the system picker**, so the user chooses
what to share each time.

**Stopping is different, and deliberately so: a human stop opens the recording in
the editor** (D48). The no-window rule is about the start — the point is that
recording begins instantly, with no UI ceremony between the impulse and the
capture. It was never a claim about what happens afterwards. An agent-initiated
stop opens nothing, because no one is there to look at it.

An earlier revision had the hotkey silently reuse the last approved target, on
the reasoning that a picker per recording costs more than a prompt per month.
Real use rejected it: silently re-selecting a previously chosen window is
surprising, and choosing the target is exactly the moment a person decides what
they are about to show someone else.

**The reversal is favourable in a way the original reasoning missed.** Because
every recording now goes through `SCContentSharingPicker` instead of the
`SCShareableContent` bypass, macOS stops charging the app its recurring monthly
re-consent prompt (§5.2). What looked like a speed-versus-friction trade was
actually speed versus *recurring interruption plus the risk of recording the
wrong window* — and the picker wins both of those.

"Instant" therefore means no window to find, no app to focus, no menu to
navigate: one keystroke to the picker, one choice, recording. It does not mean
zero UI, and §1's budget is measured accordingly.

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

### 4.13 Focus the target when recording starts

When a recording begins, Snitt brings the chosen window to the front and activates
its application.

ScreenCaptureKit captures a window correctly even when it is occluded or behind
others, so this is not required for the recording to work. It is required for the
recording to be *watchable*: a demo of a window the presenter never actually looked
at reads as a screenshot with a cursor wandering over it, and a presenter who has to
find and click their target after pressing record has spent the seconds §1 exists to
protect.

Two consequences to design around rather than discover:

- **Focus changes what is recorded.** Activating a window can dismiss a menu, close a
  popover, or move a focus ring — so the first frames may differ from what the user
  saw when they pressed the hotkey. Focus therefore happens *before* capture starts,
  not after, so the transition is not in the recording.
- **It must be skippable.** Recording a window precisely *because* it is in the
  background — a log tailing behind an editor, a progress window — is a real case.
  Auto-focus is the default, not a rule, and a modifier held while pressing the
  hotkey suppresses it.

Display captures never auto-focus; there is nothing to bring forward.

### 4.14 App shape: a document app that can also live in the menu bar

Snitt is a **standard macOS desktop application** — a regular activation policy,
a Dock icon, a main menu, a Settings window, and multiple document windows — that
*additionally* keeps a menu-bar item and a global hotkey.

This corrects a conflation made during M4/M5. §4.11 requires that recording start
from a keystroke **without a window opening**; that was implemented by making the
app `.accessory` (menu-bar-only, no Dock icon), with the editor temporarily
promoting to `.regular` while a window is open and demoting again when the last
one closes. But "can record without opening a window" never implied "has no
application shell." One is about what happens when you press the hotkey; the other
is about what the application *is*. §4.7 already called for a SwiftUI app shell,
menu bar, and settings — that was the intended shape all along.

The cost of the conflation is not cosmetic. The editor was reachable from exactly
one place: the end of a recording. **A `.snitt` bundle could be written but never
reopened** — no document type was registered, no open handler existed, and neither
the Finder nor a File menu could reach one. The non-destructive document model in
§4.5 exists so an edit is never final; an app that cannot reopen its own documents
spends that entire budget and collects none of it.

Requirements:

- **`.regular` activation policy, permanently.** The Dock icon and main menu are
  always present.
- **§4.11 is preserved exactly.** The hotkey and the menu-bar item still start and
  stop recording with no window opening. A Dock icon does not require a window.
- **The menu-bar item stays.** It is the fast path, not the whole app.
- **`.snitt` is a registered document type** with an exported UTI, openable from
  the Finder, from File ▸ Open, and from Open Recent.
- **Multiple editor windows**, one per open document.
- **A Settings window** (⌘,) consolidating what M2b–M5b accumulated as individual
  status-item toggles: agent automation, event logging, automatic update checks,
  and crash-report collection.
- **Edits persist.** A trim made in the editor is written to the bundle's EDL. The
  GUI had no write path at all — `onTrim` mutated an in-memory EDL and re-applied
  the preview, so the edit looked applied and was discarded on close (D46).
- **Multi-level undo**, and undo persists too. Autosave makes undo the only way
  back from an unwanted cut, so the two ship together or neither does.
- **An export affordance in the GUI.** Export existed only over the CLI and MCP,
  so a person could record and trim and then not get anything out (D46).

The three-frontend architecture in §6 is unchanged: the GUI remains one frontend
among three, and the CLI and MCP server continue to drive the same core. This
decision is about the GUI's own shape, not about its primacy.

## 5. Consent and privacy

### 5.1 Window-scoped capture is the default for everyone

**Every recording is window-scoped by default — human-initiated and
agent-initiated alike.** Full-display capture is available, but it is a
deliberate choice the user makes, never what happens if they just press record.

This was originally scoped to agent sessions only. That was wrong, and the first
real recording made during M1 proved it: a "Mail Password Required" notification
banner appeared in frame during a routine human-driven full-display capture. The
leak is incidental and it does not care who started the recording — a
notification, a password manager, an adjacent Slack thread. Snitt's users are
precisely the people with customer data and staging credentials on screen.

Window scoping makes the safe thing the default thing. That is the whole
argument, and it applies to every recording.

### 5.2 Selection goes through the system picker

Target selection uses **`SCContentSharingPicker`** (macOS 14+), not
`SCShareableContent` enumeration with an app-drawn picker. Two reasons, and the
second is not optional:

1. It is the OS's own window picker, so window-scoped selection is what the user
   is handed by default.
2. **It removes the monthly re-consent prompt — but only for recordings a human
   picks interactively.** macOS 15 nags apps that bypass the picker; the prompt's
   own wording is that the app "is requesting to bypass the system private window
   picker and directly access your screen and audio."

**This promise is narrower than it first appears, and the limit is structural.**
`SCContentSharingPicker` exposes only `present*()` methods and observer callbacks
— **there is no API to replay, persist, or reuse a prior selection**, and no way
to obtain an `SCContentFilter` without showing UI to a human (V12). Combined with
V10 (window IDs are per-session), that means:

> **Any recording where a human does not pick a target at that moment must call
> `SCShareableContent`, and therefore takes the monthly prompt.**

So the picker helps every recording a human starts — including the hotkey, which
now presents it on every press (§4.11). It does **not** help agent recording
(§4.8), which by definition has no human to choose a target and is therefore
structurally committed to the bypass path.

**The monthly prompt is therefore an operating cost of AUTOMATION, not of the
product as a whole.** A person who only ever records by hand should never see it.
An installation that enables agent recording will. §5.5 covers how that is
explained.

An undocumented "Persistent Content Capture" entitlement reportedly suppresses
the prompt, but Apple publishes no process for obtaining it (V11). It is not a
plan.

**Open question (V13):** whether macOS scopes the prompt per-app-capability-usage
— any `SCShareableContent` call taints the app — or per-recording-path. If the
former, even picker-driven sessions are nagged once any hotkey or agent path
ships, and the picker's remaining benefit shrinks further. Spike S4 (§14) exists
to answer this; app-wide taint is the conservative planning assumption until it
does.

**Known divergence:** M1's `CaptureTarget.available()` uses `SCShareableContent`
directly. M2 corrects this for the interactive path (see §13).

### 5.3 Additional rules for agent-initiated recordings

An agent that can record the screen is still a materially different privacy
surface, so it carries requirements beyond the universal ones above:

- **Agent-initiated recording is off by default**, behind an explicit opt-in in
  settings.
- **A visible indicator is shown for the entire duration** of any
  agent-initiated session, with a menu-bar kill switch that stops it
  immediately.
- **Agent sessions have a maximum duration**, so a hung or abandoned agent
  cannot fill the disk with a six-hour recording.
- **Agent sessions cannot silently escalate to full-display.** Where a human can
  choose full-display capture, an agent may only do so if the user has granted
  that specifically — the window-scoped default is not overridable from the
  automation API alone.

### 5.4 No persistent agent target grants — and why

An earlier revision specified a persistent per-application grant store: a human
approves an app once through the picker, agents then record it without further
interruption. **That design is deleted.** It could not work, and the reason is
worth recording so it is not re-proposed.

The grant was meant to buy frictionless agent recording. But V12 establishes that
a stored grant cannot be turned back into an `SCContentFilter` — the picker has
no replay API — so an unattended agent must call `SCShareableContent` regardless
of what Snitt's own store says, and takes the monthly OS prompt anyway. The grant
would therefore have removed a *Snitt-drawn* dialog while the *OS-drawn* one
still fired. It purchased nothing a user would notice.

Deleting it also resolves two problems it had created:

- It reintroduced the exact incidental-leak class §5.1 exists to prevent. A
  standing "agents may record Safari" grant cannot know what Safari is showing
  six weeks later, when an unattended agent uses it. With nothing persisted,
  nothing goes stale.
- Its key was a bundle identifier with no binding to a code signature, so an app
  replaced or spoofed under the same identifier would have inherited standing
  recording permission. With no trust object, there is nothing to spoof.

**What authorizes agent recording instead:** §5.3's controls, unchanged — the
global opt-in that is off by default, the window-scoped default, the maximum
session duration, the visible indicator, and the kill switch. Authorization is
per-installation rather than per-application. If per-application scoping turns
out to be wanted, it should be justified on access-control grounds and gated on
real usage evidence, not reintroduced as a friction fix it cannot deliver.

`consent_required` (§8, §11) is retained, but its meaning changes: it now means
"agent recording is not enabled in settings", not "this target lacks a grant".

### 5.5 Recurring consent is by design — explain it, do not fight it

Because agent recordings are structurally on the bypass path (§5.2), any
installation with agent recording enabled will see the macOS monthly re-consent
prompt indefinitely. Human-driven recording no longer incurs it, since the hotkey
presents the picker (§4.11). Snitt does not
attempt to architect around this; the cost of contorting the product exceeds the
cost of the prompt.

What Snitt does instead:

- **Explain it once, at first occurrence.** A brief sheet stating that macOS
  re-confirms screen access periodically, that this is OS behaviour rather than a
  Snitt fault, and what it means. An unexplained recurring prompt reads as an app
  misbehaving; an explained one reads as the platform.
- **Distinguish it in diagnostics.** `snitt diagnostics export` records the last
  OS re-consent timestamp, so support can tell an expected monthly prompt from a
  genuine regression at a glance (§12).
- **Never let it hide a real bug.** Any prompt frequency *beyond* the monthly
  baseline is a defect to fix — most likely unstable code-signing identity — not
  a UX problem to narrate. That distinction is why Developer ID signing moved
  earlier (§13).

### 5.6 Rendering captured input is opt-in, and defaults to shortcuts only

Every rule above governs what Snitt **captures**. This one governs what Snitt
**draws**, which is a different exposure with a different blast radius: a capture
stays in a `.snitt` bundle on one machine, while a render is burned into an export
and travels wherever that file goes.

The precedent is not hypothetical. D29 records a Mail password notification
captured in the first real M1 recording, during ordinary human full-display
capture — and the fix that produced (window-scoped capture by default, §5.1) does
nothing here, because this exposure is drawn *by Snitt* rather than caught
incidentally. §4.5's reversibility promise does not cover it either: toggling
keystrokes off restores the source, not a viewer who already has the export.

macOS suppresses event taps while a secure input field has focus, which covers
password fields and nothing else. A token pasted into a terminal, an API key
echoed by a shell, a recovery phrase typed into a text editor — none are secure
fields, and all are exactly what gets typed while demoing developer work.

Therefore:

- **Rendering captured input is off by default.**
- **When on, the default renders key *chords* only** — ⌘S, ⌃C, ⇧⌘P — because the
  demo value is "which shortcut did they press", and a chord is the part that
  carries it.
- **Rendering the literal character stream is a separate, per-recording opt-in.**
  Not a preference that persists silently across sessions: the decision is about
  what is on screen *this time*, so it is made when that is known.
- **Whatever is rendered is derived from the event log at render time**, never
  baked at capture — so the decision is revisable right up to the export, and the
  bundle is no more sensitive than it already was.


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
                                              (each carries `agentGranted: bool`)
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

**Agent consent.** `snitt record start` fails with `consent_required` when no
human has yet approved the target's application for agent recording (§5.4). The
error names the application and explains that a human must approve it once; the
agent is expected to relay that to its human rather than retry. `snitt targets
list` reports `agentGranted` per target so an agent can check before it tries.

**`--auto-trim`** clips dead air before the first and after the last logged input
event.

**`--auto-trim-gaps` (enhancement, beyond the M3 baseline)** additionally removes
dead air *between* events — the stretches mid-recording where nothing happens
because the presenter was reading, thinking, or waiting on a build. This is where
most of the wasted length in a real demo actually sits; head and tail trimming only
removes the bookends.

It is a ripple delete over the same event log: find runs longer than a threshold
containing no logged event, and cut them from the EDL. Three things make it harder
than the head/tail case, and all three are why it is an enhancement rather than part
of the baseline:

- **Waiting is sometimes the content.** A gap while a build runs or a spinner spins
  is exactly what the viewer needs to see. The threshold has to be generous, and
  removing a gap must be reviewable and undoable rather than silent — it edits the
  EDL, so it already is.
- **Cuts need somewhere to land.** An abrupt jump mid-sentence is worse than the dead
  air it removed. Gap removal must respect audio: never cut where either audio track
  is above the noise floor, even if no input event occurred.
- **It inherits `--auto-trim`'s event dependency.** An agent driving an app through a
  CLI or HTTP produces no OS-level input, so a purely event-driven pass would see the
  entire recording as one long gap and delete it. Any gap detection must therefore
  consider frame change as well as input events, or refuse to run when the event log
  is empty.

Both flags are limited by where input events exist. An agent that drives an app
through a CLI, an HTTP call, or a programmatic API produces no OS-level input at all,
so there is nothing to key on — these are primarily human-recording features, and
spike S1's findings on event capture determine how far they generalize. Neither is
the silence-removal that §3 excludes: that is audio-signal analysis over the whole
timeline, these are queries over an event log already on disk.

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
2. **The rule about `AVVideoCompositionCoreAnimationTool`, narrowed.** V5 is
   still true: `animationTool:` cannot be used with `AVPlayerItem` — offline and
   export only, with `AVSynchronizedLayer` as its playback counterpart. An earlier
   version of this clause turned that into a blanket ban ("not an option and was
   never in scope") and predicted it would be re-proposed anyway. It was, twice
   (D51, D64), and the ban was the part that was wrong — because it conflated two
   different kinds of change:
   - **Geometric transforms** — crop, scale, pan, zoom — are
     `AVMutableVideoCompositionLayerInstruction` transforms over a plain
     `AVMutableVideoComposition`. They need no animation tool and no custom
     compositor, and they apply identically in `AVPlayerItem` playback and
     `AVAssetExportSession` export. **This section's one-builder guarantee holds
     for them natively**, and the code already relies on it: `--scale` is such a
     transform today.
   - **Drawn content** — subtitles, click rings, keystroke chips — genuinely
     faces V5's tradeoff. Either accept an export-only burn plus a separate
     preview drawing (D51's ruling, which the product owner endorsed: the editor
     is a representation, the export is its realization), or build the custom
     `AVVideoCompositing` for one implementation. **Position-critical overlays
     are the honest case for the custom compositor**, because a click ring's
     correct position depends on the crop/zoom transform stack, so a preview
     overlay and an export burn would each reimplement that math and drift.

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
- **Agent requests an ungranted target (§5.4):** return `consent_required`
  immediately, naming the application and stating that a human must approve it
  once. Surface the picker to whoever is at the machine as a side effect, but
  never make the agent wait on it — an automation run parked behind an invisible
  modal is worse than a clean failure.
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

## 13. Milestones and priority

D65 retired the validation gate; D66 supplies what sequences work instead. The
list below is therefore in two parts: what shipped (history, kept because the
reasoning in it is still load-bearing) and what is next, **in priority order**.

### Shipped

- **M0** Spikes S1, S3 (§14)
- **M1** Capture to disk — one `SCStream`, video + system audio + mic
- **M2a** Stable code-signing identity; `SCContentSharingPicker` adoption;
  window-scoped capture as the universal default (§5.1); menu-bar status item +
  kill switch (§5.3); global hotkey presenting the picker on every press
  (§4.11, D42); stop-and-copy (§4.1)
- **M2b** The automation surface: `SnittAutomation`, IPC + version handshake
  (§10), the `snitt` CLI, the MCP server (§4.8), consent enforcement for
  agent-initiated recording (§5.3)
- **M3** Event logging (data only), markers + WebVTT chapters (§4.12),
  `--auto-trim`, auto-focus on record (§4.13), progressive permission onboarding
  (§4.10), export `--max-size`, `snitt inspect` + manifest, capture health
  (§12.1), git context (§7)
- **M4** EDL model, timeline UI with marker jump-points, preview (explicit
  passthrough composition slot, §9)
- **M5** Packaging: notarization, Sparkle, diagnostics (§12)
- **M5c** The app shell (§4.14): permanent `.regular` activation, main menu,
  Settings window, `.snitt` document type + open/Open Recent, multiple editor
  windows (D45)
- **M5f** The editor (D58, D59): output-duration timeline, selection independent
  of cutting, cuts as reversible identified folds, separate audio/video tracks,
  an editable marker track, zoom and snapping. *Recorded here retroactively — it
  was decided and built while this list still ran M5c → M5d, which is the drift
  D47's conformance guard exists to catch.*
- **v0.1.0** — built, signed, notarized, stapled, published. Not a gate (D65).

### Next, in order

Ranked by D66's five pillars, with **hard dependencies named** — ranking by value
must not produce an unbuildable order.

1. **Crop.** The cheapest item in the queue: `renderSize` plus a layer-instruction
   transform, extending the call `CompositionBuilder` already makes for `--scale`.
   No schema change, no permission, no dependency, and previewable live (D64).
2. **The editor's known defects.** Whatever `docs/superpowers/notes/field-notes.md`
   is carrying. "Focused in-app editing" is a D66 pillar and the editor is the
   surface used daily; a defect in built work outranks a new feature.
3. **Transcription (D62)** — spike the on-device API first (S6), then transcript
   editing. Two D66 pillars at once (transcription, on-device) and, with the agent
   surface, one of the two things no competitor combines.
4. **`auto-deep-trim` (D57)** — *needs 3*. Honestly priced now that D59 refuted the
   `HealthSampler` path: it needs its own per-span signal, and D62's transcript is
   a better one than an RMS threshold.
5. **Agent discovery (S5/D63), then M5e's agent primitives** — *S5 gates M5e*.
   Pause/resume, screenshot, marker transcripts as WebVTT, D53's correlation
   primitive and `paused` state. D66's first pillar, and the differentiator with
   the widest moat: no competitor has an agent surface at all.
6. **The shared window-frame track**, then **visible clicks** — *5 is independent
   of this; do whichever is wanted*. Record the window's frame (position + size)
   over time as ONE capture-side track, then click positions on top of it. Serves
   every window-relative overlay, so it is built once rather than per feature.
7. **D56 Tier 2 — segments** (slice, reorder, per-track cuts). A schema *and*
   algorithm replacement: `KeptRanges` sorts cuts and walks a forward cursor, so
   it cannot express order at all (D59).
8. **Zoom + follow-mouse** — *needs 6 (coordinates) and 7 (per-segment
   attachment)*. Cheap in mechanism, gated on both prerequisites.
9. **Visible keyboard input** — **BLOCKED on §5.6**, which does not exist yet. A
   policy gap, not a priority one (D67).
10. **M5d durability**, rescoped to what protects an unattended agent run.
    Replan required: the original plan had six verified defects.

**Pick a licence.** Not a milestone and not expensive, but "open source, free, no
subscription" is one of D66's five reasons this exists, and the repo is private
today *because* the licence is unsettled. Choosing one unblocks going public,
which in turn unparks update hosting.

### Parked, with the condition that would unpark each

- **Update hosting (D54)** — parked until the repo is public. `SUFeedURL` points
  at `releases/latest/download/appcast.xml`, which 404s to anyone unauthenticated
  while the repo is private. Public repo → the existing appcast works as designed.
  *Not cut* — the mechanism is built and correct.
- **M6 (overlay desirability probe)** — mostly answered. D64's features were
  requested directly, and D65 makes the maintainer's judgement the signal, so
  there is no desirability left to probe. What survives is narrower: whether the
  capture-side data clicks and keystrokes need is worth recording.
- **M7 (custom compositor)** — mostly emptied. Crop and zoom leave via layer
  instructions (D64, as corrected). What remains is the honest case for a custom
  `AVVideoCompositing`: position-critical overlays whose placement depends on the
  crop/zoom transform stack, where an export-only burn and a preview overlay would
  each reimplement the same math and drift apart.
- **M8 (licensing; Mac App Store)** — **contradicted, not deprioritized** (D66).
  There is no licence to enforce and no subscription to gate. A Mac App Store
  variant remains conceivable but has nothing to do with licensing, and sandbox
  rules would fight §4.9's helper-process design.

**Enhancement, unscheduled:** none. `auto-deep-trim` is item 4 above.

### Why signing moved into M2

M1 is ad-hoc signed, which has no stable code identity: TCC keys grants to the
code signature, so every rebuild risks resetting the Screen Recording
authorization. That would stack an *unpredictable* prompt on top of the
*predictable* monthly one from §5.2 — and unlike the monthly prompt, this half is
self-inflicted and fixable.

The rule §5.5 states is that the monthly baseline is explained while anything
beyond it is a defect. That rule is unenforceable while the app's own identity
changes on every build, because no one could tell the two apart. A stable signing
identity therefore has to precede the features whose behaviour depends on grants
persisting — which is M2, not M5.

### What differentiation means here

*This section was "The v0 gate". D65 retired the gate and D66 replaced its
premise; the questions below survive as questions worth answering, not as
conditions anything waits on.*

v0 shipped as **record + trim + export + agent automation, with no overlay
rendering**. The two questions it was built to answer:

1. Does anyone choose Snitt over `Cmd+Shift+5` for the record → trim → share
   loop?
2. Does an agent actually record with Snitt and attach the result to a PR?

Not "does anyone use this." Both still matter — but D66 reframes what they are
evidence *for*. Measured feature by feature against the paid field rather than
against `Cmd+Shift+5`, the trim/export loop is table stakes: CleanShot X and
Screen Studio both have editors, cursor-follow zoom, click highlighting and
keystroke display. **The differentiation is the combination, not any member of
it** — and the two members no competitor pairs with the rest are the agent
surface and on-device transcription (D66).

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

**S4 — Is the monthly re-consent prompt scoped per-app or per-path?** §5.2's
remaining value, and §4.11's cached-target design, both assume macOS charges the
prompt only to recordings that bypass the picker. If instead it is keyed to the
app having called `SCShareableContent` *at all*, then picker-driven sessions are
nagged too once any hotkey or agent path ships, and picker adoption buys almost
nothing. **Honest cost: the prompt is monthly, so this needs weeks of observation
on a build that uses both paths — it cannot be answered from documentation.**
Until it is, assume app-wide taint (the conservative reading) and do not claim
the picker as a product-wide mitigation.

**S5 — How does an agent find out Snitt exists?** §4.8 built the *capability* — a
CLI and an MCP server over one core — and stopped there. Neither is **installed**
and neither is **announced**: `Scripts/make-app.sh` copies only `SnittApp`,
Sparkle and the icon into the bundle, so someone who installs Snitt.app has no
`snitt` and no `snitt-mcp` on the machine at all, and nothing anywhere tells an
agent host that either would exist. §13's second validation question — does an
agent record with Snitt and attach the result to a PR — cannot be answered in
that state, so this spike gates M5e rather than following it.

Two problems hide inside the one question, and the options split differently
across them:

- **Registration** — the binary exists and the host knows how to launch it.
- **Disclosure** — an agent mid-task *thinks to reach for it*. A tool list
  answers "how do I call this"; it does not answer "why would I record my
  screen." An agent that never considers making a demo never reads the schema.

The options are not mutually exclusive. Naming which layer does which job is
the spike's real output:

| Option | Buys | Costs |
|---|---|---|
| **MCP server** — built, needs registering | Typed schemas, no shell, and §4.8's shared core means it cannot drift from the CLI | Registration differs per host (`claude mcp add`, `.mcp.json`, Cursor, Codex TOML) and a hand-delivered app (D54) has no installer to do it; a registered server costs context in **every** session forever, whether or not anyone records anything; MCP-speaking hosts only |
| **Skill / plugin** | Carries *when* and *why* plus the workflow around the verbs — drive the UI with your own tools, mark each step, stop, inspect, attach. Progressive disclosure keeps the standing cost to one description line | Anthropic-specific; installs by writing into `~/.claude/skills`, and an app doing that silently is its own trust question; prose drifts from the flags it describes — the failure §10's version handshake exists to catch, with no equivalent for documentation |
| **CLI self-description** — `snitt --help`, `snitt agent-guide` | Zero install, any agent with a shell, and generated from the same request types so it cannot go stale | Answers disclosure only *after* discovery: the agent must already know the word `snitt` |
| **`AGENTS.md` / `CLAUDE.md` snippet** | Cross-agent, cross-host, and per-project so it appears only where recording is wanted | Hand-pasted, goes stale, and is prose rather than capability |
| **`snitt setup`** — detect installed hosts, write each one's config | Makes registration one command, and is the only option that also repairs "no binary on the machine" | Owning another tool's config format is a maintenance tail; every host that changes it breaks this |

**Cheap and unblocked whatever the answer:** MCP's `initialize` result carries an
`instructions` field for exactly this — server-level "what this is for" as
against per-tool "how to call it" — and `Sources/snitt-mcp/main.swift:146-150`
does not set it.

**What the spike must answer:** whether disclosure needs an artifact of its own
at all, or whether a registered server with a good `instructions` string is
enough; and whether the app bundle should embed both binaries behind a `setup`
command or ship them separately.

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
| Custom compositor is the hardest component and could slip | Parked (§13), and D64 shrank it — crop and zoom exit via layer instructions, leaving only position-critical drawn overlays; mid-export fallback (§11); cross-architecture golden frames (§15) |
| Differentiation is thin feature-by-feature against the paid field, not just against free built-in recording | Answered by D66: the differentiator is the *combination* — agentic support, transcription, focused editing, on-device, open source — not any single feature. The risk therefore moves: it is now that the combination is never completed, not that one feature is missing |
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
| Incidental capture of notifications and private content | §5.1 window-scoping is now the default for ALL recordings, not just agent ones — prompted by a Mail password notification appearing in the first real M1 recording |
| **Monthly re-consent is permanent for hotkey and agent capture** | **No mitigation exists.** V12 makes the picker unusable for non-interactive capture, and the Persistent Content Capture entitlement is undocumented (V11). §5.5 explains the prompt rather than avoiding it. Do not let a changelog imply M2 closed this — picker adoption fixes it for manual record-button use only |
| Unstable code-signing identity causes prompts beyond the monthly baseline | Stable signing moved into M2 ahead of grant-dependent features (§13); any excess prompt frequency is then a defect, not narration |
| The picker's remaining benefit may be smaller than assumed | Spike S4 (§14) tests whether the prompt is app-wide; conservative assumption until answered |

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
| V7 | On macOS 15, system audio is covered by the Screen Recording grant (the pane is "Screen & System Audio Recording"); the microphone is a separate TCC service. | **CONFIRMED** — Apple settings taxonomy; consistent with `capturesAudio` (V2) needing no extra grant while `captureMicrophone` prompts separately. |
| V8 | macOS 15 shows a **recurring monthly** screen-recording re-consent prompt, whose wording is that the app "is requesting to bypass the system private window picker". | **CONFIRMED** — widely reported behaviour of macOS 15; wording quoted from the prompt itself. |
| V9 | The prompt is triggered by *any material ScreenCaptureKit use that does not go through `SCContentSharingPicker`* — **specifically including asking for `SCShareableContent`**. Using the picker avoids it. | **CONFIRMED** — matches V8's prompt wording and reported developer guidance. **M1's shipped `CaptureTarget.available()` is on the triggering path.** |
| V10 | `SCWindow.windowID` is a per-session integer; a relaunched app produces new windows with new IDs, so it cannot be a durable permission key. | **CONFIRMED** — `CGWindowID` semantics; IDs identify window instances, not logical windows. |
| V11 | A "Persistent Content Capture" entitlement exists that suppresses the monthly prompt entirely, but Apple publishes no documentation or process for obtaining it. | **CONFIRMED as reported; UNOBTAINABLE in practice** — treat as unavailable, not as a fallback plan. |
| V12 | `SCContentSharingPicker` exposes only `present*()` methods plus configuration/observer plumbing; results arrive via `SCContentSharingPickerObserver` callbacks. **There is no API to replay, persist, or reuse a prior selection non-interactively** — no method yields an `SCContentFilter` without showing UI to a human. | **CONFIRMED — re-verified against the SDK header** (`SCContentSharingPicker.h`, macOS 15 SDK), not a doc summary. The complete member list is: `sharedPicker`, `defaultConfiguration`, `maximumStreamCount`, `active`, `addObserver:`, `removeObserver:`, `setConfiguration:forStream:`, and four `present*` variants. Nothing replay-, reuse-, restore-, or last-selection-shaped exists. **Refutes premises under D30, D31, D32 and §4.11.** |
| V13 | Whether the monthly nag is scoped per-app-capability-usage (any `SCShareableContent` call taints the whole app) or per-recording-path. | **UNVERIFIED — and expensive to verify.** The prompt's own wording describes app behaviour, and TCC tracks per responsible process, so app-wide taint is the likely reading. Confirming it empirically needs weeks of observation because the prompt is monthly. Treat app-wide as the conservative planning assumption. |
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

| D29 | Window-scoped capture is the default for EVERY recording, not just agent-initiated ones | The incidental-leak risk does not depend on who pressed record. Proven, not hypothesised: a Mail password notification was captured in the first real M1 recording, during ordinary human full-display capture | M1 verification record; §5.1 | Decided | safety-scoped-too-narrowly |
| D30 | ~~Target selection moves to `SCContentSharingPicker`; makes the grant one-time~~ **SUPERSEDED by D33** — the picker cannot serve non-interactive capture (V12), so it makes the grant one-time only for manual record-button use | macOS 15 shows a recurring MONTHLY re-consent prompt to apps that bypass the system picker — its wording is literally "requesting to bypass the system private window picker". Enumerating our own targets would nag every user forever, defeating the one-time-grant promise. The picker also gives window scoping for free, so D29 and D30 are one change | §4.6 (which already cited the picker), §5.2 | **Superseded** → D33 | permission-recurs-not-persists |

| D31 | ~~Agent target grants per application bundle identifier, persisted until revoked~~ **SUPERSEDED by D34** — a stored grant cannot become an `SCContentFilter` (V12), so it removed a Snitt dialog while the OS prompt fired anyway | Agents have no human to drive `SCContentSharingPicker`, which would strand automation on the bypass path and its monthly nag (§5.2). Per-window grants are impossible because `SCWindow.windowID` is a per-session integer that changes on relaunch, so the grant would silently stop matching; the bundle identifier is the stable key. Displays stay excluded — a display grant is exactly what window scoping exists to prevent giving away casually | §5.2, §5.4; `SCWindow.windowID` semantics | **Superseded** → D34 | unstable-identity-as-permission-key |
| D32 | ~~An *ungranted* agent request returns `consent_required`~~ **SUPERSEDED by D35** — the mechanism survives, its trigger changes: there are no grants to lack | An automation run parked behind a modal no human can see is worse than a clean failure — the agent cannot report it, cannot time out meaningfully, and cannot ask for help. Failing fast lets the agent relay the blockage to its human, which is the only path to resolution | §5.4, §11 | **Superseded** → D35 | invisible-modal-blocks-automation |

`conformance: 2026-09-02` (post-M1)

### Pass 3 — M2 scope review (2026-09-02)

Triggered by: six decisions (D27–D32) landing after M1, all into M2. Roster: all
five personas, resumed with retained context for one feedback round.

**The pass turned on one verified fact.** V12 — `SCContentSharingPicker` has no
API to replay or reuse a selection non-interactively — refuted premises under
D30, D31, D32 *and* §4.11 simultaneously. Two personas reached it independently
(principal engineer, product/UX); it was then confirmed directly against Apple's
documented method list rather than accepted on their word.

| # | Decision | Rationale | Rests on | Status | Shape |
|---|---|---|---|---|---|
| D33 | §5.2 corrected: the picker removes the monthly prompt **only for recordings a human picks interactively**. Hotkey capture and agent recording are structurally on the bypass path, so the prompt is a permanent operating cost | V12 + V9. The original claim read as a solved problem; it was solved only for the minority path | V9, V12; §4.8, §4.11 | Decided | promise-narrower-than-stated |
| D34 | The persistent per-application agent grant store is **deleted**, not deferred | It bought nothing: the grant could not produce a filter, so the OS prompt fired regardless — it removed only a Snitt-drawn dialog. Deleting also moots the §5.1 contradiction (nothing persists to go stale) and the bundle-ID spoofing hole (no trust object to spoof). Red team escalated from defer to delete once V12 landed | V12; §5.1, §5.3 | Decided | mechanism-without-benefit |
| D35 | `consent_required` retained, redefined: it means "agent recording is not enabled in settings", not "this target lacks a grant" | The immediate-failure behaviour from D32 was right and survives; only its trigger changes | D32, D34 | Decided | mechanism-survives-premise-change |
| D36 | ~~§4.11 uses a cached last-approved target for the hotkey~~ **SUPERSEDED by D42** — real use rejected silent target reuse, and presenting the picker every time also removes the monthly prompt for human recording | A monthly prompt costs once a month; a picker on every hotkey press costs once per recording, forever. For "record this repro now", per-use cost dominates | V12; §1, §5.2 | **Superseded** → D42 | per-use-cost-beats-periodic-cost |
| D37 | §5.5 added: explain the recurring prompt at first occurrence, log the last re-consent timestamp in diagnostics, and treat any frequency **beyond** the monthly baseline as a defect rather than something to narrate | Operator's distinction: accept-and-explain is right for an OS constraint and wrong for a self-inflicted one | V12; §12 | Decided | accept-os-fix-self-inflicted |
| D38 | Picker adoption folds into M2 as its first PR, **not** a separate gated milestone | Its urgency fell once it stopped being a product-wide nag fix. Still worth the day it costs for manual recording, which is the majority interaction. Pragmatist retracted its own "hard dependency" framing — grants and picker are independent | V12 | Decided | urgency-rested-on-refuted-premise |
| D39 | Stable code-signing identity moves **into M2**, ahead of grant-dependent features (was M5) | TCC keys grants to code identity, and ad-hoc signing changes it every build. §5.5's rule — monthly is expected, more is a bug — is unenforceable while the app's identity is unstable, because nobody could tell them apart | Operator; §5.5, §13 | Decided | rule-unenforceable-without-precondition |
| D40 | Export `--max-size`, `snitt inspect` + manifest, capture health, and git context move from M2 to M3 | None bears on either v0 validation question. Shrinks M2 to what actually proves the product | §13 v0 gate | Decided | scope-not-serving-the-gate |
| D41 | Spike S4 added: is the monthly prompt scoped per-app or per-path? | Decides whether D36's cached-target design and the picker's residual value are real. **Cannot be answered from documentation** — the prompt is monthly, so it needs weeks of observation. Conservative assumption (app-wide taint) holds until then | V13 | Decided | assumption-needs-time-not-research |

**Open question carried forward (V13):** the S4 answer. If the prompt turns out
app-wide, D38's remaining justification weakens further and picker adoption may
be worth dropping entirely. Recorded rather than guessed.

`conformance: 2026-09-02` (pass 3)

### Post-M2a — reversed by real use (2026-09-02)

| # | Decision | Rationale | Rests on | Status | Shape |
|---|---|---|---|---|---|
| D42 | **The hotkey presents the picker on EVERY press.** Supersedes D36's cached-target reuse | The product owner used the built app and rejected target-reuse as surprising: choosing the target is the moment you decide what you are about to share. The revisit gate is satisfied by the strongest evidence available — real use of the real thing, against a decision that had rested on an assumption about preference. **The reversal also removes the monthly re-consent prompt for all human recording**, because every capture now flows through `SCContentSharingPicker` rather than the enumeration bypass. The original trade was framed as speed vs. friction; it was actually speed vs. recurring interruption plus wrong-window risk | Direct user feedback on a running build; V9, V12; §4.11, §5.2 | Decided | assumption-about-preference-tested |

D36 is marked **Superseded** above. The cached-target machinery is retained rather
than deleted — the automation surface (M2b) has no human to drive a picker and
still needs to re-resolve a stored reference.

| D43 | Focus the target window when recording starts, by default, suppressible with a modifier; never for display captures | ScreenCaptureKit captures occluded windows fine, so this is about the recording being watchable rather than possible — and about not spending the §1 budget hunting for the window after pressing record. Focus happens BEFORE capture starts so the activation transition is not in the recording; skippable because deliberately recording a background window is a real case | §1, §4.13 | Decided | default-with-an-escape |
| D44 | **Superseded by D57**, which specifies the criteria and the interface. `--auto-trim-gaps` removes dead air BETWEEN events; recorded as an unscheduled enhancement, not a milestone item | Most wasted length in a real demo sits mid-recording, not at the bookends. Held back because it needs three things the baseline does not: a generous threshold (waiting on a build is sometimes the content), audio-aware cut points (never cut where either track is above the noise floor), and frame-change detection as well as input events — without which an agent-driven recording, which logs no OS input, would be seen as one long gap and deleted entirely | §8, D23, S1 | Decided | enhancement-needing-its-own-evidence |

`conformance: 2026-09-02` (post-M2a)

### Post-M5 — reversed by real use (2026-09-06)

| # | Decision | Rationale | Rests on | Status | Shape |
|---|---|---|---|---|---|
| D45 | **Snitt is a standard desktop app that also lives in the menu bar**, not a menu-bar app that sometimes opens a window. Corrects the `.accessory` shape M4/M5 shipped | The product owner used the built app and named the gap: it is a menu-bar item, not an application. The cause was a conflation — §4.11's "record without opening a window" was implemented as "have no application shell," which it never implied. §4.7 had asked for a shell, a menu bar, and settings from the start. The concrete cost was that a `.snitt` bundle could be written but **never reopened**: no document type, no open handler, and the editor reachable only at the end of a recording. §4.5's non-destructive model pays for reopenability and was collecting none of it. Same evidence class as D42 — real use of the real thing, against a decision that rested on an assumption | Direct user feedback on a running build; §4.5, §4.7, §4.11, §4.14, §13 | Decided | conflation-caught-by-use |

**This gates v0 rather than following it.** §13's first validation question asks
whether anyone prefers Snitt to `Cmd+Shift+5` for record → trim → share. Testing
that against a shell the product does not intend to keep risks a "no" that cannot
be distinguished from a real one — the most expensive kind of negative result,
since it looks like an answer.

### Post-M5c refinement — adversarial pass (2026-09-06)

| # | Decision | Rationale | Rests on | Status | Shape |
|---|---|---|---|---|---|
| D46 | **GUI edits persist, with multi-level undo.** The editor autosaves the EDL to the bundle after each applied change; ⌘Z/⇧⌘Z walk a real undo stack and each step persists too. A GUI **Export** affordance calls the existing `CompositionBuilder`/`MovieExporter` path, and exporting re-copies to the clipboard, superseding the stale stop-time copy | Six independent sources — a Phase 2 code check plus five personas reasoning from different mandates and unable to see one another — found the same defect: `EditorWindowController.onTrim` appended to an in-memory `edl.cuts` and re-applied the preview, so a trim **looked** applied and was discarded on window close. The only EDL writers were `Recorder.swift:288` (full-range, at capture) and `AutomationHost.swift:387` (the CLI). Export was likewise CLI/MCP-only. §13's first validation question is the record → trim → share loop; it was unanswerable through the GUI. Autosave alone would be unsafe — it commits a mistaken cut instantly — so undo is part of this decision rather than a follow-on, and undo persists for the same reason the trim does | `EditorWindowController.swift:79-84`; `PreviewController.swift:107-121`; grep: no EDL write in `Sources/SnittApp/` outside `AutomationHost`; §4.5, §4.14, §13 | Decided | capability-reachable-by-machines-not-people |
| D47 | **A spec promise must map to a test, a task, or an explicit "not yet."** Checked mechanically, so a normative claim cannot silently go unimplemented | Three verified instances of the same shape: §4.7's app shell went unbuilt through five milestones and was caught only when the product owner used the app; §11's "disk full mid-recording: finalize the partial file" and "unfinalized bundle found at launch: offer recovery" are both absent from the code and appeared nowhere on the roadmap. Under this project's own recurrence rule, three hits means patching instances is off the table and the class needs a structural guard. The spec is the binding authority for every plan, so a promise it makes that nothing implements is a defect in the authority itself | §4.7, §11, §4.14, D45; Operator + Platform persona findings, both code-verified | Decided | promise-with-no-conformance-check |
| D48 | **A human stop opens the recording in the editor**; §4.11's "without opening a window" governs the START only | The spec contradicted the built app and the contradiction was latent until an M5c reviewer hit it: §4.11 said the hotkey starts *and stops* with no window, while §9 and the `humanStopOpensEditor` test deliberately open the editor on a human stop. Both behaviours are intended; only the wording was wrong. Confirmed by the product owner — "definitely open the recording in the app on stop". Resolved in favour of the app's actual behaviour, which is also the better product: the moment a recording ends is exactly when someone wants to trim it, and D46 now makes that edit persist. Agent-initiated stops still open nothing, since no human is present | §4.11, §9, D46; `humanStopOpensEditor`; direct product-owner confirmation | Decided | spec-contradicted-intended-behaviour |

| D49 | **Snitt coordinates agent demos; it does not drive input.** The agent keeps using its own UI-driving tools. Snitt adds pause/resume, screenshot, and markers with transcripts. **Provisional** | A compelling product needs an agent to *produce* a demo, not merely film one — and generic control tools cannot coordinate with the recording: they cannot pause while the agent thinks, cannot mark the moment being demonstrated, and cannot see the recorded window. Coordination supplies exactly that gap. Driving input from Snitt was considered and deferred, for a reason worth keeping: posting synthetic events needs an **Accessibility grant**, the most powerful TCC permission on the machine, and it would mean a prompt-injected agent could drive the Mac rather than only film it. Recording observes; control acts, and §5's posture makes that Snitt's problem rather than the agent's. **Revisit trigger, named in advance:** if agent-produced demos are poor *because* input is not on the recording clock — clicks and their markers drifting apart — that is new evidence qualifying a reopen under the revisit gate, and the answer becomes an opt-in, audit-logged control surface rather than an unconditional one | §4.8, §4.12, §5, §12; product-owner direction 2026-09-06 | Decided (provisional) | scoped-to-avoid-a-permission |
| D50 | **A marker carries a transcript, exported as WebVTT** — subtitles first, synthesized speech later | §4.12 already generates WebVTT chapters from markers, so the sidecar and its plumbing exist; a transcript field rides the same path. Burning captions was initially deferred here on the belief that it needed M7's compositor — **superseded by D51**, which establishes it does not. WebVTT remains the storage and interchange form; burn-in is an export option over it | §4.12, §7, §13 (M7 deferral) | Decided | smallest-change-that-makes-it-real |

| D51 | **Burned-in subtitles are an export option**, superseding D50's deferral. Export gains two menu items: **Share** (`NSSharingServicePicker`, as QuickTime does) and **Export As…** with format, size, include-subtitles and include-markers | D50 deferred burned-in captions on the belief they needed M7's compositor. They do not: `AVVideoCompositionCoreAnimationTool` composes text at export and works with `AVAssetExportSession`. That removes the reason for the deferral, and burned-in is the only form that survives the paste — Slack and Discord render neither a sidecar `.vtt` nor a soft `tx3g` track, so a narrated demo without burn-in is narrated for nobody who matters. **§9 does not apply here, and an earlier draft of this entry wrongly said it did.** §9's shared-builder rule governs the *composition* derived from the EDL — which frames survive, in what order, from which tracks — so that a cut lands in the same place in the file as in the editor. Subtitle rendering sits on top of that as presentation. The editor is a **representation** of the edit; the export is its **realization**, and they need not match pixel for pixel any more than a text editor's cursor appears in the saved file. So the animation tool being export-only (V5) is not a divergence to accept, it is simply how the two surfaces draw the same data. **What must match is the data, not the drawing:** a transcript attached to a marker at 12.4s burns at 12.4s with the same text. That is a correctness property and gets a test; the rendering mechanism does not | §4.12, §9, §7, D50, V5 | Decided | deferral-removed-by-a-capability-check |

| D52 | **Ship v0 before M5d and M5e.** The release runbook runs first; M5d is rescoped to what protects an unattended agent run and replanned; M5e splits, agent primitives before export UI | A refinement pass found three milestones inserted before a gate whose stated purpose is to stop exactly that, each with a good local argument, while the gate itself never moved closer. The deciding fact was a mechanism rather than an argument: `Recorder.stop()` finalizes unconditionally even when `finish()` throws, so in a **human** session every M5d failure still ends in a saved take — the window closes, the status item lies, the user presses stop, the data survives. Confusing and disclosable, not validation-corrupting the way D45's unopenable bundle was. The exception is an **unattended agent** run, where nobody presses stop and `maxDuration` is the only backstop — which is exactly §13's second gate question, and why M5d survives at reduced scope rather than being cut. **The release itself was unstarted, uncosted work already on the critical path**: seven runbook items are marked unverifiable in-repo, including a Gatekeeper-clean launch on a second machine and a full 0.1.0 → 0.1.1 update cycle | §13, §11, D45, D47, D49; `Recorder.stop()`; `docs/superpowers/notes/release-runbook.md` | Decided | gate-receding-one-good-argument-at-a-time |
| D53 | **The agent surface gains a correlation primitive and a `paused` state** whenever M5e is built | `mark` stamps at IPC-processing time (`Recorder.swift:249`) — after the agent's own tool reports done, after a subprocess spawn or MCP round trip — so the click-to-marker drift D49 named as its own revisit trigger is **already structural**, before the feature that would supposedly cause it. Pause/resume inherit the same call-and-stamp shape. Having `screenshot` implicitly drop a marker at the frame it captured gives "what I saw" and "what I said about it" one shared offset rather than two independent call times. Separately `StatusInfo` is exactly `{recording, sessionID, elapsedSeconds}` with no session-listing verb, so an agent that pauses, crashes and is restarted cannot discover its own live session; `paused` must also settle whether paused time counts against `maxDuration`, and §5.3's visible indicator must show it distinctly — a human at the machine is the only fallback when an agent forgets to resume | `Protocol.swift:84,132-141`; `Recorder.swift:249`; §5.3, §12, D49 | Decided | trigger-already-firing-before-the-feature-ships |

| D54 | **v0 is hand-delivered; the repo stays private and update hosting is deferred.** `SUFeedURL` is knowingly a dead URL until hosting is decided | The release published correctly — notarized, stapled, `spctl`-clean, both assets uploaded — and then `releases/latest/download/appcast.xml` returned **404 to any unauthenticated request**, because the repository is private. Every check built across eight milestones ran *authenticated*, so `gh` saw the assets and no one saw the hole: the same shape as the unstapled archive, correct on the machine that made it and broken everywhere else. The product owner is keeping the repo private until licensing is settled and it is GA-ready, which makes hand-delivery the right call rather than merely the expedient one — v0 goes to 5-10 known people as a zip, and the hosting decision waits until there is a **second** version to ship, which is the first moment it actually pays for itself. Consequence accepted: automatic checks are already off by default (R3), so nothing fails silently in the background, but a user who clicks **Check for Updates…** will see an error until a feed exists | §4.3, §13, R3; `gh repo view --json isPrivate`; the 404 above | Decided | verified-only-while-authenticated |

| D55 | **Customizable record and marker hotkeys** — queued as the first post-v0 item, deliberately NOT inserted before the gate | Requested by the product owner immediately after v0 shipped. Right-sized on inspection: `HotkeyCombination` already carries `keyCode`/`modifiers` and `HotkeyMonitor(combination:)` already takes one, so the work is persistence, a key-recorder in the Settings window M5c shipped, and re-registration on change. It is **not urgent**, because the failure it addresses already degrades well: `main.swift:112` surfaces an alert naming the conflict and pointing at the menu bar, so a tester whose ⌥⌘5 is already bound is told rather than left with a dead app. **Queued rather than built for the reason D52 exists**: three milestones were inserted before a gate designed to stop exactly that, each with a good local argument, and this is a good local argument arriving four commits after the gate finally opened. If tester feedback names hotkey conflicts as a real friction, that is evidence and it moves up; if nobody mentions it, that is also evidence | §4.11, D52; `HotkeyMonitor.swift:6-24`, `main.swift:106-125` | Decided (queued) | good-argument-arriving-right-after-a-gate |

| D56 | **The editor gains a real timeline model** (§4.4, two tiers). Tier 1: output-duration timeline, selection independent of cutting, cuts as reversible identified folds that expand in place, separate audio/video tracks, an editable marker track. Tier 2: per-track cuts when sync is unlocked, and **slice for reordering** | Product-owner direction after v0 shipped. Split into tiers because Tier 1 is a richer UI over the model that already exists — the one real model change being that cuts need **identity**, since `TimeRange` is `{start, end}` with nothing to address a cut by for removal — while Tier 2 changes what an edit *is*. Reordering in particular retires the EDL's founding assumption: "source minus ranges" is order-implicit and monotonic, and a sequence of reorderable segments is neither. Everything downstream that maps a source time to an output time — `TimeRangeMapping`, `MarkerMapping`, `CompositionBuilder`, WebVTT burn-in timing — assumes that monotonicity today. This project has already shipped one output-time-versus-source-time defect (M4b, where the timeline fed output-time durations while the EDL consumed source-time cuts and a second trim silently did nothing); Tier 2 makes that class structural rather than incidental. **Sequencing per D52:** recorded now, built on evidence — Tier 1 is what a v0 user will feel, Tier 2 is what an editor eventually needs, and nothing about which comes first should be decided before someone has trimmed a real recording | §4.4, §7, §9, D50, D52; `EditDecisionList.swift`, `MarkerMapping.swift` | Decided (queued, tiered) | ui-request-with-a-model-change-inside |

| D57 | **`auto-deep-trim`** — supersedes and specifies D44's `--auto-trim-gaps`. A span is **dead air** only when *all* hold: audio is nothing but background noise, video is pixel-identical, no mouse or keyboard events, no marker, and no subtitle still owed reading time. Exposed as **conservative / default / aggressive** in the app, and as both that preset flag and individual per-criterion flags in the CLI | D44 held this back needing three things — a generous threshold, audio-aware cut points, and frame-change detection as well as input events. This entry supplies all three plus a fourth D44 missed: **subtitles need reading time**, so a span cannot be dead merely because nothing moved while a caption is still on screen (§4.12, D50). **The cheap path was believed to already exist — REFUTED by D59**, which found `HealthSampler` keeps no timestamps and reduces audio to a single whole-capture RMS, so per-span dead-air detection cannot come from it. The original (wrong) reasoning is kept below because it is why this was scoped as cheap:: `HealthSampler` computes per-frame variance *during* the `AVAssetWriter` pass for §12.1's capture health, so frame-change detection can extend that sampling at near-zero cost. Doing it post-hoc instead means a full decode pass of the movie — a real architectural fork, and the reason to decide it before building. **Two cautions.** *Naming was settled before it could reach a user*: an earlier draft said "strict", which reads either as strict about preserving footage or strict about removing it — opposite meanings in a feature whose job is deletion. **conservative** has one reading, and names the axis (how much footage survives) rather than the enforcement. *Agent recordings log no OS input by construction* (D44, D49), so for an agent-driven demo the input criterion is always satisfied and frame-change detection carries the entire decision — which is precisely the case D44 warned would otherwise see one long gap and delete the whole recording. Interacts well with D56 Tier 1: reversible cut folds make an automatic trim inspectable and individually undoable, rather than a bulk edit a user must accept whole | §8, §4.12, §12.1, D23, D44, D49, D50, D56; `HealthSampler.swift` | Decided (queued) | enhancement-specified-not-yet-scheduled |
| D59 | **M5f is Tier 1 plus zoom/snapping; slice, reorder, per-track cuts and auto-deep-trim are cut from it.** `snitt trim`'s cut-discarding is fixed first, as its own change | A six-persona refinement pass, run before any of the plan was built. Four personas independently found it reached too far past Tier 1, and **D56's own text already said so** — "nothing about which comes first should be decided before someone has trimmed a real recording" — which my plan bundled past anyway, reproducing D52's pattern one layer inside D58's exception to it. Two task premises were refuted outright: `KeptRanges` sorts cuts and walks a forward cursor, so it **cannot express segment order at all** (slice/reorder is a schema *and* algorithm replacement, not a builder change), and `HealthSampler` keeps **no timestamps** with audio as a **single whole-capture RMS**, so per-span dead-air detection is impossible from it — the opposite of D57's "the cheap path already exists". **Zoom and snapping were added**, because the plan missed what `TrimGesture`'s own comment identifies as the real obstacle: at ~0.75s/pixel on a ten-minute recording "a deliberate short cut is silently swallowed", and folds make density *worse* by packing kept footage into fewer pixels. A plan for "the UI does not suck" that never changes x-per-second was solving the wrong problem | §4.4, §13, D52, D56, D57, D58; `KeptRanges.swift:13-42`, `HealthSampler.swift:26`, `TrimGesture.swift:44-56` | Decided | plan-reached-past-its-own-evidence-gate |
| D60 | **`snitt trim` must preserve existing cuts**, and `edit.json` gains an enforced `schemaVersion` gate | Found by refinement, not use, and it is a **live data-loss bug in shipped v0.1.0**: `EditDecisionList.trimmed(keeping:duration:)` builds `var cuts: [TimeRange] = []` from scratch and returns it, so `existing.cuts` is read and discarded — make interior cuts in the editor, run `snitt trim`, they are gone. `autoTrimCuts` does the same. §4.8 and §6 hold that the CLI and GUI are one model, not two; a CLI that silently deletes the GUI's edits is two. Separately `schemaVersion` is declared on both `EditDecisionList` and `RecordingMetadata` and **compared nowhere**, which matters because D54 makes updates hand-delivered, so old and new builds coexist on one machine and `edit.json` is the only place cuts live — an old build partially decodes a newer file and the next write destroys what it could not represent. Gate the version loudly, test migration against a **real captured v0.1.0 bundle** rather than a remembered literal, and record the schema in diagnostics so "my cuts disappeared" leaves evidence | §4.8, §6, §7, §12, D54; `EditDecisionList.swift:70-77`, `AutomationHost.swift:390-400` | Decided | cli-and-gui-quietly-disagreeing |
| D61 | **The v0 gate has not opened.** v0.1.0 is built, notarized and publishable, but has been handed to nobody; it opens when someone other than the maintainer uses it | Correcting a framing D52 and D58 both rest on. Shipping the artifact proved the *release pipeline* — notarization, stapling, EdDSA signing, appcast generation, all verified end to end, and worth having done — but §13's two questions need users, and there are none. The practical consequence is that "queued pending evidence" (D55, D56 Tier 2, D57, M5d, M5e) has been accumulating against a signal **nobody is collecting**, which makes it deferral without a resolution date rather than evidence-gated sequencing. The maintainer's call: get the UI good enough to hand over first. That also retires the pending 0.1.1 hand-delivery and D54's update-hosting question — neither matters until there is a recipient | §13, D52, D54, D58; direct product-owner correction 2026-09-06 | Decided | mistook-publishable-for-published |

| D58 | **M5f — the editor — is built before validation is judged**, ahead of M5d and M5e. Bundles D55, D56 (both tiers) and D57 | The product owner's judgement after v0 shipped: *"Nobody will like this if the UI sucks."* That is D45's argument applied where I had failed to apply it — I used it to justify the app shell gating v0 (testing with a UI you do not intend to keep risks a "no" indistinguishable from a real one) and then queued the editor work behind evidence anyway. §13's first validation question asks whether anyone prefers this trim/export loop to `Cmd+Shift+5`; a timeline that shows source duration, draws cuts as irremovable overlays, and cannot separate selecting from cutting is not that loop, so a "no" from it would measure the UI rather than the premise. **This is a deliberate exception to D52, not a repeal of it**: D52's rule was that milestones stop being inserted before an *unopened* gate. v0 has shipped, so this is post-gate work being sequenced ahead of other post-gate work, on the strength of the one judgement no review process can supply | §4.4, §13, D45, D52, D55, D56, D57 | Decided | applied-my-own-argument-late |

| D62 | **Automatic audio transcription, and editing through it** — queued as an enhancement, not scheduled | Product-owner direction. Two capabilities that share one mechanism: transcribe captured audio to timed text, and let that text become an editing surface. **On-device only.** macOS ships speech recognition that runs locally, and using a hosted service would reverse §3's "v1 is local-only" and §5's whole posture in the most sensitive way available — Snitt records screens and microphones, so shipping that audio off the machine is categorically different from shipping a crash log. If no local API is adequate, the feature waits; it does not go to a server. **The pieces already exist**: `LoggedEvent.transcript` (D50) is the field, `WebVTTChapters` is the sidecar, `Timebase` converts source to output time, and both mic and system audio are captured separately (`captureMicrophone`/`captureSystemAudio`), so speaker separation is free rather than inferred. **What it unlocks is larger than captions.** With word-level timestamps, deleting a phrase in the transcript becomes a `Cut` over its span — text-based editing over the EDL that already exists, which is a far better answer to §1's speed budget than dragging pixels. It also gives D57's `auto-deep-trim` a real signal: "nobody is speaking" is a sharper criterion than an RMS threshold, and D57's audio criterion currently has no per-span data at all. **Unresolved, needs a spike before planning**: which local API, its accuracy on screen-recording audio, whether word-level timings are exposed, and its cost on a laptop while recording versus after | §1, §3, §4.12, §5, D50, D51, D57; `EventLog.swift:34`, `WebVTTChapters.swift`, `CaptureSession.swift:7-8` | Decided (queued) | field-exists-mechanism-does-not |

| D63 | **Agent-facing discovery gets a spike (S5) before M5e is planned.** The question is not whether to build an MCP server — one exists — but **registration** (the binary is on the machine and the host can launch it) and **disclosure** (an agent thinks to reach for it). Separately, and not an open question: the shipped bundle carrying neither client binary is a **defect**, not one of the options | Product-owner direction: agents need to be told Snitt exists. Verified while framing it: `Scripts/make-app.sh` copies `SnittApp`, `Sparkle.framework` and `AppIcon.icns` into `Snitt.app` and nothing else, so `snitt` and `snitt-mcp` live only in `.build/` on the machine that compiled them — the entire agent surface §13's second validation question depends on is absent from the artifact that was notarized, signed and released. No script installs them anywhere either. That is D61's shape one layer down: the pipeline was proved, the capability was not delivered. **Why a spike rather than a task:** the two problems have different answers and the cheap-looking one is the wrong one. A tool list is read at *call* time and answers "how do I invoke this"; nothing in it answers "why would I record my screen," which is read at *decide* time — so registering the server may satisfy registration and leave disclosure untouched. The reverse also holds: a skill can describe a workflow perfectly and still name a binary that is not there. Weighing them needs the options laid against both axes, which is what S5 does. **One item needs no spike and no waiting:** MCP's `initialize` result has an `instructions` field for server-level purpose and `snitt-mcp` does not set it | §4.8, §6, §8, §10, §13, §14, D52, D53, D54, D61; `Scripts/make-app.sh:150-170`, `build/Snitt.app/Contents/MacOS/`, `Sources/snitt-mcp/main.swift:146-150`, `MCPBridge.swift:110-250` | Decided (spike queued) | capability-built-shipped-nowhere |

| D64 | **Crop, per-segment zoom + follow-mouse, visible clicks and visible keystrokes** — queued, and they **re-scope M6/M7 rather than joining them**. Crop is unblocked today. The other three are blocked on **capture-side data that is not recorded**, not on a renderer | Product-owner direction. The framing to correct first: these read as overlay features, so they look like M7 ("custom compositor + overlay rendering", conditional on M6's desirability probe). **Amended (refinement, 2026-09-07): the mechanism below is wrong for two of the
four.** Crop and zoom+follow-mouse are **not** animation-tool work at all — they
are `AVMutableVideoCompositionLayerInstruction` transforms (`setTransform`,
`setTransformRamp`) plus `renderSize`, over a plain `AVMutableVideoComposition`.
That needs no custom compositor AND no animation tool, and unlike the animation
tool it applies in `AVPlayerItem` playback as well as export — so those two are
previewable live and satisfy §9's one-builder rule natively. The code already
does exactly this for `--scale` (`CompositionBuilder.swift:245-251`), and
`PreviewController.swift:90-91` hands the same composition to the player. Only
visible clicks and keystrokes add new pixels, and only they face V5's tradeoff.
**Two things falsify that.** D51 already established `AVVideoCompositionCoreAnimationTool` composes timed layers at export with `AVAssetExportSession` and no custom compositor — that is what moved subtitle burn-in out of M7, and click rings and keystroke chips are the same mechanism over different data. And M6 asks whether anyone wants overlays; the person who would decide has now asked for them twice. So M7's expensive half was never the drawing. **The real blocker, verified:** `InputEventMonitor`'s callback is `(EventKind) -> Void` — it passes the *kind* and nothing else. The `CGEventTap` mask is `keyDown | leftMouseDown | rightMouseDown`, and `LoggedEvent` is `{id, timeSeconds, kind, label, transcript}`. So a click is recorded as "a click happened at 12.4s" with **no x/y anywhere in the pipeline**, a keystroke carries **no key identity**, and mouse *movement* is not captured at all — not sparsely, not at any rate. Visible clicks and visible keystrokes each need a field added through three layers (tap callback, `LoggedEvent`, `events.json` schema, with D60's version gate); follow-mouse needs a position track that does not exist. **An earlier draft of this entry priced that wrongly**, assuming it meant widening the tap mask to `mouseMoved` — the one input class that fires continuously — and inheriting the tap's Input Monitoring grant. It does not. Cursor position is `NSEvent.mouseLocation`, which needs no TCC grant and no tap, and `CaptureSession.handle(_:of:)` already runs per sample buffer with its `presentationTimeStamp` in hand (the per-frame call is `sink.append` at `CaptureSession.swift:219` — an earlier draft of this entry cited :215, which is inside `if !didBegin` and fires once at session start), so position can be sampled **on the frame clock** — exactly the shape D57 wanted from `HealthSampler` and did not get, since these samples would carry timestamps by construction. Follow-mouse is therefore the CHEAPEST of the three, not the most expensive, and is the one that needs no permission the app does not already have. **A second, separate problem for clicks:** the tap reports **screen** coordinates while §5.1 makes capture **window**-scoped by default, and a window can move mid-recording — so a click ring needs a screen→window→video mapping over time, not a coordinate.
**Amended (refinement, 2026-09-07): that cost belongs to follow-mouse too, and an
earlier draft charged it only to clicks.** `NSEvent.mouseLocation` returns global
screen coordinates — the same coordinate class — and a mapping error there is
*worse*, because it mis-frames the whole exported shot rather than misplacing one
ring. **Both features are therefore served by one shared capture-side track: the
window's frame (position + size) over time**, recorded once and reused by every
window-relative overlay. **Zoom + follow-mouse is per *segment*, and segments do not exist**: slice is D56 **Tier 2**, and D59 verified `KeptRanges` sorts cuts and walks a forward cursor, so kept spans are derived positionally with no identity to hang a property on. This is now the second feature demanding segment identity, which is evidence *for* Tier 2 rather than a reason to defer it again. **Crop is the exception and can go first**: a composition-time transform needing no event data, stored in the EDL per §4.5 so `capture.mov` stays pristine, and interacting only with `--max-size` (§8), whose byte search walks scale and quality over dimensions crop changes. **Privacy, which is not a detail here:** rendering keystrokes makes anything typed during a recording legible to everyone who watches it. macOS suppresses event taps for secure input fields, which covers password fields and nothing else — a token pasted into a terminal is not a secure field. §5 is the strictest part of this spec and this is the first feature that would put captured input on screen, so it needs a §5 rule of its own before it needs a renderer | §4.2, §4.5, §5.1, §8, §9, §13 (M6, M7), D51, D56, D57, D59, D60; `InputEventMonitor.swift:32-52`, `EventLog.swift:22-40`, `KeptRanges.swift:13-42` | Decided (queued, tiered) | overlay-features-blocked-on-capture-not-rendering |

| D65 | **The maintainer is the primary customer, and "queued pending evidence" is retired as a category.** Work is now sequenced by *differentiation* — how much a feature makes this better than the alternatives its author rejected — not by waiting on external validation. §13's two questions survive as questions, but they no longer gate | Product-owner correction: *"I am the primary customer... I am building this for me — because I don't like the other available options... we don't need to wait for people to use it if even I don't like it yet."* This resolves, rather than contradicts, what D61 had already found: queued items were accumulating against a signal **nobody was collecting**, which made "evidence-gated" indistinguishable from "deferred indefinitely". The signal exists and always did — it is the author's own use, available at zero latency, and it is a *better* instrument than five strangers for the question actually being asked, which is whether this is worth using instead of the tools they already rejected. **What this repeals:** the deferral half of D52, D55, D56 (Tier 2), D57, D61, D62 and D64 — every "queued pending evidence" status becomes queued pending *priority*. **What it does not repeal:** D52's mechanism, which was never really about users — it was that a milestone gets inserted ahead of others on a good local argument, and the fix is an explicit priority order rather than a gate. Nor does it touch the evidence standard for *facts*: claims about the code are still verified against the code, and this project's recurring defect has been plans resting on capabilities that turned out not to exist (D59's `KeptRanges`, D59's `HealthSampler`, D64's own follow-mouse mispricing three paragraphs up). Whose judgment orders the work has changed; what counts as a checked fact has not. **The reprioritization this forces:** the differentiators are the editor (D56), automatic zoom/follow-mouse and visible clicks (D64), transcription with text-based editing (D62), and `auto-deep-trim` (D57) — the features that make this unlike `Cmd+Shift+5`. Against them, several built or scheduled items serve a distribution that does not exist and should not consume another hour until it does: **update hosting** (D54 — a private repo, one machine, and `git pull && ./Scripts/make-app.sh` is already a faster update path than Sparkle), **M8 licensing and the Mac App Store variant**, and the parts of §12 and crash reporting that exist to hand a stranger something to attach to a support thread. Notarization, signing and the diagnostics that are already built stay — they are sunk, they cost nothing to keep, and TCC grant stability depends on the signing half | §1, §2, §13, §12; D45, D52, D54, D55, D56, D57, D58, D61, D62, D64; direct product-owner correction 2026-09-07 | Decided | gate-built-for-an-audience-of-one |

| D66 | **The differentiator is the COMBINATION, not any feature in it: agentic support, transcription, focused in-app editing, on-device, and open source (free, no subscription).** Supersedes D65's list of "differentiators", which named features that are individually table stakes | The refinement pass asked what the maintainer's own rejection of existing tools was actually about, because the feature-by-feature answer came back negative: CleanShot X already ships click highlighting, keystroke display and cursor-following zoom; Screen Studio's entire positioning is automatic cursor-follow zoom; Descript popularized transcript-based editing. Against `Cmd+Shift+5` those are differentiators, and §13's original framing measured against `Cmd+Shift+5` — but the field a tool is judged against is the one its user actually chose between, and that field is paid, closed, and mostly subscription. **Answered directly by the product owner:** *"The reasons no existing software is good enough are the combination of: agentic support, transcription, focused in-app editing (trim, cut, etc), on-device, and open source (free, no subscription)."* That is a coherent and checkable thesis rather than a preference — no competitor pairs an agent surface with local transcription, and none is free and open source. **What it changes.** (1) The two members with a real moat are the **agent surface** (§4.8 — no competitor has one at all) and **on-device transcription** (D62 — Descript is cloud, which also violates the on-device pillar), so those rank above the visual-polish features. (2) The polish features are still worth building: matching table stakes is what makes a tool usable by its author, and D58's rule stands — nobody likes it if the UI is bad. They are just not the reason it exists. (3) **M8 is contradicted, not deprioritized**: there is no licence to enforce and no subscription to gate. (4) **Update hosting (D54) is unparked by the same pillar it was parked under** — the appcast 404s only because the repo is private, and "open source" resolves that; the mechanism is already built and correct. (5) Choosing a licence becomes a small unblocking task rather than a milestone, because the repo is private today *precisely* because the licence is unsettled | §1, §2, §4.8, §13, §16; D54, D57, D58, D62, D64, D65; product-owner statement 2026-09-07; competitive check labelled PLAUSIBLE (web-sourced) | Decided | measured-against-the-wrong-field |
| D67 | **Visible keyboard input is BLOCKED on §5.6, not merely deprioritized** — and §5.6 now exists: rendering captured input is off by default, renders key *chords* only when on, and needs a separate per-recording opt-in for the literal character stream | Found by two personas independently, from different mandates. D64 said keystroke rendering "needs a §5 rule of its own before it needs a renderer" — a **policy** gap. D65 then repealed "the deferral half of D64" in bulk, which does not distinguish a policy gap from an evidence gap, so on the spec's own text the feature silently became ready-to-build; D65's own differentiator list dropped it with no stated reason, leaving it genuinely ambiguous whether that was deliberate. **Verified:** §5's five subsections all governed *capture* consent and contained no rule about *display*. The harm is asymmetric with everything else in §5 — a capture stays in a bundle on one machine, a render travels with the export — and this project has already had the incidental-exposure incident (D29, a Mail password notification in the first real M1 recording), whose fix (window-scoped capture) does nothing against an exposure Snitt draws itself. §4.5's reversibility promise likewise protects the source, not a viewer who already received the file. macOS's secure-input suppression covers password fields and nothing else, which excludes every way a secret actually reaches a developer's screen: pasted into a terminal, echoed by a shell, typed into an editor | §4.5, §5.6, §13, D29, D64, D65; Red-team + Product/UX personas, convergent | Decided | policy-gap-repealed-as-if-it-were-an-evidence-gap |

`conformance: 2026-09-07` (post-D66 refinement pass)

### Termination

**Condition 1 — converged.** The single contested item settled in one
cross-examination round (budget allowed two); the remaining seven Important items
were uncontested and recorded directly; the conformance walk is clean.

**Verdict: Proceed.** Next step is `superpowers:writing-plans` against §13.

Not covered by this pass, by design: adversarial review of code (none exists
yet — that belongs to `/code-review` once the plan produces a diff), and a
zero-trust plan-vs-implementation audit. This was the light, memory-carrying pass.
