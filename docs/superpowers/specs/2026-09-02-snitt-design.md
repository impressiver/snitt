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

Direct distribution (Developer ID, notarization, Sparkle updates) ships first and
avoids fighting the sandbox over global input monitoring. *Third-party licensing
was part of this plan and was removed by D66 — the project is open source, free,
and has nothing to license.*

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

### 4.6 Minimum OS: macOS 26 (Tahoe) — raised from 15 (D77)

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

**Raised to macOS 26 on 2026-09-08 (D77).** Everything above still explains why
14 is not enough; it no longer explains the floor, which is now 26. The reason
is different in kind: nothing here needed a macOS 26 API, but the code had
already stopped compiling at 15 and nobody could tell, because every build
happened on a machine running 26. `Package.swift` also moves to
swift-tools-version 6.2, which is where `.macOS(.v26)` exists.

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
- **Recording with nobody at the keyboard is a separate, EXPIRING opt-in**
  (D95). Enabling it confirms Screen Recording while a person is present —
  that is its whole mechanism, since the grant is otherwise requested lazily
  at first record — and it stops authorizing anything thirty days later, on the
  same cadence macOS re-confirms the underlying permission (§5.5). It is
  subordinate to the global opt-in above, so turning that off withdraws this
  too, and its lapse never blocks recording that the global opt-in already
  allowed.

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
- **M4b** The timeline: gesture-driven trimming over the EDL, output-time vs
  source-time separation (`Timebase`)
- **M5b** In-app updates: Sparkle, the EdDSA signing key, appcast generation,
  notarization and stapling
- **M5c** The app shell (§4.14): permanent `.regular` activation, main menu,
  Settings window, `.snitt` document type + open/Open Recent, multiple editor
  windows (D45)
- **M5f** The editor (D58, D59): output-duration timeline, selection independent
  of cutting, cuts as reversible identified folds, separate audio/video tracks,
  an editable marker track, zoom and snapping. *Recorded here retroactively — it
  was decided and built while this list still ran M5c → M5d, which is the drift
  D47's conformance guard exists to catch.*
- **v0.1.0** — built, signed, notarized, stapled, published. Not a gate (D65).
- **Export knobs and pre-flight (D80, 2026-09-08)** — `--resolution`, `snitt
  estimate`. Recorded here because it arrived as product-owner direction rather
  than off this list, and a reader of the priority order would otherwise not
  know it exists.
- **The six items that finished off the old numbered order** (restructured out of
  "Next" on 2026-09-09, D90): crop with live preview, undo, `CropRect.composing`
  and a CLI verb; the editor's known defects, cleared twice (2026-09-08 and
  2026-09-09); transcription (D62) across four slices including in-place
  correction, speaker-bleed warning and D81's vocabulary; `auto-deep-trim` (D57)
  in editor, CLI and MCP, consuming waveforms, filmstrip, events AND transcript
  word spans; M5e's agent primitives and S5's registration question; and visible
  clicks for reported input (D78). The reasoning that produced them stays in
  their decision-log entries.
- **CI and repo hygiene (2026-09-08/09)** — GitHub Actions on every PR and on
  main, the macOS floor raised to 26 (D77), `docs/DEVELOPING.md`. CI runs the
  five targets a headless runner can finish; export, composition, the editor and
  the timeline are verified locally only.

### Next — unblocked, in value order

**Read this list's premises against the code before starting an item.** Five times
now it has described work that was already built (crop, D73, M5e/S5, D57's word
spans, D86). D91 adds a mechanical guard; the habit is still the primary defence.

1. **D84 — editor keyboard shortcuts, through a shortcut REGISTRY.** Space to
   start/stop, rewind, jump to previous/next marker. Product-owner direction
   (2026-09-09) added the shape: the bindings live in one registry that both
   installs the menu items and renders a **Help ▸ Keyboard Shortcuts** dialog, so
   the help cannot drift from what the keys actually do — the same drift class
   `ServerInstructionsTests` exists to guard, and cheaper to prevent than to
   detect. **Cheaper than its own decision entry assumed**: the bare-key mechanism
   already ships. `Cut Selection` binds bare Backspace via
   `keyEquivalentModifierMask = []` (`AppShell.swift:141-145`) and
   `AppDelegate`'s `NSMenuItemValidation` is what stops it swallowing the key
   app-wide (`main.swift:529-534`), which is exactly the "space is also a
   character" trap D84 worried about, already solved once. **SHIPPED 2026-09-10** — `KeyboardShortcutRegistry` installs the Playback menu and renders Help ▸ Keyboard Shortcuts from one array, and `MarkerNavigation` supplies prev/next. The `absent:` marker is retired rather than deleted quietly: D91's guard exists to make exactly this transition visible, and it failed on the commit that created the type.
2. **D86's missing half — a Full Screen choice in the recording UI.** The capture
   is BUILT: `StartOptions.displayID` → `TargetReference.display(id:)` →
   `SCContentFilter(display:excludingWindows:)`, with the resolver erroring on a
   vanished display, `ConsentPolicy` checking `displayID` before
   `bundleIdentifier`, and `MCPBridge` requiring exactly one of the two. Only the
   human-facing affordance is missing. Sized accordingly.
3. **Pick a licence — SETTLED 2026-09-09 (D92): MPL-2.0, plus a CLA.** `LICENSE`,
   `CLA.md`, `CONTRIBUTING.md` and the Exhibit A notice on all 273 Swift files
   are in. What remains is the act this unblocks, which is not a code change:
   **make the repository public**, which un-404s
   `releases/latest/download/appcast.xml` and restores auto-update for every
   copy already in the field (D54). Before flipping it, the 2026-09-07 clean-to-
   open-source check in `field-notes.md` still stands — with one judgement left
   open there: going public also publishes `docs/superpowers/`, including every
   plan, execution ledger and field note.

4. **Visible keyboard input** — **gated by §5.6** (D67): off by default, chords
   only when on, literal character stream a separate per-recording opt-in. The
   policy is settled; what remains is key identity through the tap callback,
   `LoggedEvent` and `events.json` behind D60's version gate. Confirmed unbuilt
   2026-09-09: `InputEventMonitor.kind(for:)` maps `.keyDown` to a bare
   `.keystroke` and reads no `keyCode` (`InputEventMonitor.swift:48`).
5. **D56 Tier 2 — segments** (slice, reorder, per-track cuts). A schema *and*
   algorithm replacement: `KeptRanges` sorts cuts and walks a forward cursor, so
   it cannot express order at all (D59) — confirmed 2026-09-09 at
   `KeptRanges.swift:12-34`. **Re-priced 2026-09-09; it is the most expensive and
   most dangerous item here, and it was under-priced.**
   `EditDecisionList.swift:249-257` records that D60's schema-version gate "never
   fired for any bundle that actually exists": bundles written before the
   stamp-on-encode fix declare `schemaVersion: 1` while carrying schema-2,
   `id`-bearing cuts. The fix is shipped, but **those mis-stamped bundles are on
   disk**, and this item is precisely the non-additive change that comment warns
   "turns the same situation into exactly the silent, unrecoverable loss
   `EditDecisionListError`'s own message promises to prevent." CI cannot catch it
   — `SnittExportTests` and `SnittAppTests` are excluded because they hang on a
   headless runner. **Prerequisite: a migration test against a real pre-fix
   bundle**, run locally under an untrimmed `swift test`, before any merge. `absent: Segment` (D91).

### Blocked — and the edge that blocks each

Dependencies are edges, not positions. An item here cannot start until its edge
clears, whatever its value.

- **Zoom + follow-mouse** — *needs the window-frame coordinate track (for observed
  coordinates) and D56 Tier 2 (for per-segment attachment)*. Cheap in mechanism,
  gated on both.
- **M5d durability**, rescoped to what protects an unattended agent run —
  *needs its replan first*: `docs/superpowers/plans/2026-09-06-snitt-m5d-durability.md`
  carries a DO-NOT-EXECUTE banner naming six verified defects. **Defect #6 is not
  a live bug and must not be cited as one** (established 2026-09-09): it describes
  stale UI state "after an interruption finalizes", but no interruption path
  exists — a grep for `SCStreamDelegate`/`didStopWithError`/`ENOSPC` across
  `SnittCapture` and `RecordingCoordinator` returns nothing — and the *other*
  unattended path is already handled. `AutomationHost.expire()`
  (`AutomationHost.swift:1111-1135`) clears state and records
  `AuditOutcome.capped` on both `.stopped` and `.failed`, and its comment names
  defect #6's exact failure as the thing the watchdog exists to fix. The real
  gap is that stream-death and disk-full are **unhandled**, which is a different
  and still-unobserved claim.

### Queued enhancements — requested, recorded, NOT ranked

Direction from the product owner that was deliberately not built when it arrived.
Listed here because a decision-log entry alone is invisible to planning. **Their
position is an open question** — they have not been ranked against the list above.
D84 and D86 left this section on 2026-09-09 once their real cost was measured.

- **D83 — per-channel gain automation.** A level line per audio lane with
  draggable points and eased segments. *Edge: needs D56 Tier 2, OR a design that
  re-derives the envelope through `Timebase` rather than raw `KeptRanges`.* D83's
  own text says the envelope "must be re-derived against `KeptRanges`" — the
  structure Tier 2 replaces. Verified 2026-09-09: `Timebase`
  (`Timebase.swift:44-97`) already wraps `KeptRanges.compute` as the single
  conversion point and markers survive cuts through it, so the edge is a design
  choice rather than a hard gate — but the insulation is partial, since
  `CompositionBuilder`, `TimelineView`, `TranscriptPane`,
  `EditorWindowController`, `AutomationHost` and `RecordingIcon` all still read
  `KeptRanges` directly. `absent: GainEnvelope` (D91).
- **D96 — estimate a GIF's size by encoding a sample of frames.** Take about
  ten frames spread across the timeline, encode just those as a GIF, and
  extrapolate to the full export. Requested 2026-09-13.

  *Why it fits.* `ExportEstimator` refuses GIF outright today and says why —
  "GIF size tracks how much the picture MOVES rather than how long it runs" —
  so the export sheet shows no estimate at all for the one format whose size
  is hardest to guess. Sampling is the same move `MovieExporter.exportSlice`
  already makes for mp4, which exists "so a size can be MEASURED rather than
  modelled", and spreading the samples is what captures average motion rather
  than one quiet second.

  *The objection that does NOT apply, checked rather than assumed:* scattered
  frames would normally compress worse than consecutive ones, biasing an
  extrapolation high. Not here — `EstimateError`'s own text records that these
  frames "carry no interframe compression", so per-frame cost is roughly
  independent of neighbours and the extrapolation is defensible.

  *The one that does:* ImageIO builds a SINGLE global colour map across every
  frame — `GIFWritePlugin::writeAllFramesWithGlobalColorMap`, the same fact
  behind the 2026-09-13 crash. A palette fitted to ten frames is a better fit
  for each of them than a palette that must cover three hundred, so the sample
  will likely come out smaller per frame than the real export. That is a
  calibration factor, and it has to be MEASURED against real exports rather
  than reasoned about — the direction is predictable, the magnitude is not.

  *Two constraints on the sample itself.* It must be encoded at the scale the
  export will actually use, after `GIFExporter.maximumWidth` clamps it, or it
  describes a different file. And it must stay bounded: GIF encoding is what
  crashed the app, and an estimate that runs on every format change is exactly
  where an unbounded encode would hurt most. `absent: GIFSizeEstimator` (D91).

- **D95 — an opt-in that lets an agent record with nobody at the keyboard.**
  Requested 2026-09-13, built the same day. The use case is real and specific:
  a remote-control session where an agent is working a machine no one is
  sitting at, and the recording is how anyone sees what it did.

  *The capability already existed; the policy is what blocked it.* D42 makes
  `RecordingCoordinator` resolve every HOTKEY target through
  `PickerTargetResolver`, but `startForAgent` has always taken a forced
  `CachedTargetResolver`, which builds an `SCContentFilter` by enumerating
  `SCShareableContent` with no picker at all — `CaptureTarget`'s own
  deprecation text calls that "the bypass path (§5.2)" for "headless callers
  with no human to drive a picker". So this was a decision about consent, not
  a feature to invent.

  *What actually stood between the two, measured rather than assumed.* Reading
  the whole agent path turned up exactly one thing needing a person: **Screen
  Recording is requested lazily, at first record.** `RecordingCoordinator`'s
  preflight calls `ScreenRecordingAccess.ensureGranted()`, and macOS
  re-confirms that grant periodically for anything on the bypass path (§5.5).
  An unattended machine therefore records fine until the OS decides otherwise,
  and then fails with nobody there to approve anything. Nothing else in the
  path prompts: the consent sheets moved out of the critical section
  deliberately, so an agent gets `permission_denied` over the socket rather
  than a modal on an empty desk.

  **So the mechanism is confirmation, not a new permission.** Turning the
  setting on is the one instant a person is guaranteed to be at the machine,
  so that is when the grant is confirmed — `UnattendedRecordingToggle` runs
  §4.10's `PermissionLadder` against `.screenRecording`, and the ladder's
  existing rule does the rest: a refused grant persists NOTHING and the
  checkbox reverts, so a checkmark can never sit over a permission the app
  does not have. That is the "trigger the required macOS permissions when
  enabled" half of the request, and the reason a bare stored flag would be a
  lie.

  *It partially reopened §5.4, and only one of its objections survived.*
  **Spoofing** is answerable now: the automation socket reads the caller's
  pid, executable and signing identity (2026-09-12), which is the
  "access-control grounds" §5.4 itself said such scoping would need.
  **Staleness** still bites and is what shaped the design — "a standing grant
  cannot know what the target is showing six weeks later, which is the
  incidental-leak class §5.1 exists to prevent". The answer is that the grant
  **expires**: `UnattendedRecordingGrant` stops authorizing anything
  `renewalDays` after the confirmation, and renewing means switching it off
  and on again, in front of the machine. A grant that expires cannot go six
  weeks stale.

  *Thirty days is not a taste decision.* It matches the macOS re-consent
  cadence the grant exists to track (§5.5, and `ConsentExplainer`'s own copy
  says "about once a month"), so the two renewals coincide instead of
  interleaving — a person who renews before leaving has renewed both. The
  number is INTERPOLATED into the Settings help text from the constant that
  enforces it, and a mutation line pins that: help text saying thirty while
  the grant expires at forty-five is worse than no help text, because they
  would leave the machine believing it.

  *The hard external limit, which no opt-in removes:* macOS re-prompts, and
  that prompt needs a human. So the feature degrades honestly at that moment
  instead of failing silently. `screenRecordingDeniedMessage(unattended:)`
  says something different in each of the three states — nothing extra when
  the feature is off, "macOS has withdrawn access and that needs someone at
  this Mac" when the grant is live, and "lapsed N days ago, switch it back on
  to renew" when it is not — and `DiagnosticsBundle` records the grant beside
  the three OS permissions, because "screenRecording: granted" next to
  "unattendedRecording: lapsed 3 days ago" says something neither line says
  alone.

  *What did not change:* §5.3's indicator for the whole duration, the session
  cap, the kill switch, and the global opt-in staying off by default — the new
  grant is SUBORDINATE to it, composed rather than stored, so turning agent
  recording off withdraws unattended recording with no second value that could
  be left disagreeing. No recording that worked before this now needs the new
  opt-in; a lapsed grant means the feature is off until renewed, not that
  agent recording is blocked. And it is Settings-only, with no status-item
  toggle: the menu is the fast path, and a grant renewed monthly after reading
  what it costs is the opposite of one.

- **D94 — an on-device generated title for a recording.** Name a bundle after
  what is IN it, instead of `Snitt-1789163327.snitt`. Deferred 2026-09-12 after
  being built as far as a measurement and then stopped.

  *Measured, not estimated* (`FoundationModels`, macOS 26.5.2, 2026-09-12):
  `SystemLanguageModel.default.availability` is `.available` with 23 supported
  languages, and a `@Generable` title over a real transcript took **6.65s**
  from the transcript alone and **10.83s** with the git branch added. Quality
  tracked the context: "SoundCloud Song Search" with the branch, bare
  "SoundCloud" without.

  *Why it was stopped rather than shipped:* three edges, in the order they
  bite. (1) **Confabulation on a thin transcript is worse than a timestamp** —
  a wrong-but-confident name is trusted, so the recording becomes harder to
  find than the number it replaced; this needs a floor on transcript length or
  a confidence gate before it is safe. (2) **It is the first non-reproducible
  thing in this format.** §7's whole pitch is that everything re-derives from
  immutable inputs, and the same bundle re-analysed yields a different title —
  so the result must be STORED, never recomputed, which is a change to
  `meta.json` rather than a display detail. (3) **~10s cannot sit on the stop
  path**; it has to run in the background and update the name when it lands,
  which means the editor has to tolerate its own document being renamed under
  it.

  *And one that only bites if it grows:* if it ever emits chapters as well as a
  title, `EventSource` has no case for a model-generated event — neither
  `observed` nor `reported` is true — so it needs a third case rather than a
  reuse of `reported`, or `autoTrimRange` and `InspectReport.inputEventCount`
  will count invented events as input. §5 also makes a generated title a new
  artifact derived from speech, so the audit record should say a model produced
  it. `absent: GeneratedTitle` (D91).

- **D100 — narration you WRITE, from a `+` in the transcript header.**
  Requested 2026-09-14. **Built 2026-09-14.**

  *What it is.* Stand at a moment, press `+`, type what should be said there,
  and it becomes a phrase on the voiceover track. `AuthoredNarration.words`
  splits the line into words at `SpeechRate.wordsPerSecond`; the pane's rows,
  the captions and the phrase chips then treat it exactly as they treat
  narration the recogniser heard, because it carries the same `track`.

  *It pays before D101 exists.* A screencast whose narration is written rather
  than recorded still gets subtitles, still gets a transcript to edit, and
  still shows the narration lane — and rewriting a sentence beats re-recording
  a take to fix one.

  *`isAuthored` is load-bearing, not informational.* `deleteWords` removes a
  word by CUTTING THE FOOTAGE underneath it, which is right for speech — the
  way to unsay something is to remove the seconds in which it was said — and is
  nonsense for a line with no seconds behind it. Without the flag, selecting a
  written phrase and pressing delete cuts whatever video the script happened to
  be anchored over. Authored words are removed from the transcript instead, and
  a mixed selection does each to its own words.

  *Anchored in SOURCE time*, like every other word, so a cut above a line does
  not drag it. *Timed at the reading speed* — an assumption a synthesiser will
  replace with real durations, and the guess least likely to surprise, since
  the caption is then on screen for as long as it takes to read. The constant
  moved to `SpeechRate` in `SnittDocument` to be reachable from both layers,
  the same move `TranscriptParagraphs.breakSeconds` already made.

  *Undo of the FIRST line removes the transcript rather than emptying it*: an
  empty transcript reads as "the recogniser ran and heard nothing", which is a
  different and more discouraging claim than "you have not written anything
  yet".

  *Deleting is a keystroke, not a button* (requested in the same breath).
  Select words — shift extends the range — and press delete. The range runs
  along DISPLAY order rather than `transcript.words`, because rows are grouped
  by voice: extending along the stored order selects words the reader can see
  are not between the two they clicked.

  *No absence marker*: this is BUILT, and `AuthoredNarration` is declared. An
  `absent:` on a shipped decision is a claim `PlanClaimsTests` falsifies
  immediately, which is the marker working — it caught exactly that here.

- **D101 — QUEUED: speak the written narration.**
  Requested 2026-09-02, recorded here 2026-09-14 — it had been asked for and
  never written down, which is the failure D91 exists to prevent.

  *The input already exists*, which is the point of ranking D100 first: the
  authored phrases ARE the script, so this decision is about synthesis and
  nothing else. `AVSpeechSynthesizer.write(_:toBufferCallback:)` renders to
  buffers rather than to the speakers, which is what an offline render needs.

  *Timings become real.* D100 times a written line at the reading speed because
  it has nothing better; a synthesiser returns the durations it actually
  produced, so the words should be re-timed from the render rather than left at
  the guess. That is the one place this is not purely additive.

  *It writes the third audio track*, the one `AudioTrackOrder.canonical`
  already reserves and `VoiceoverTrack` already places — so the composition
  side is done. What is not decided: whether a synthesised take replaces a
  recorded one on the same track or coexists, and what happens to a written
  line that has been left behind by an edit.

  *§5 makes this a generated artifact.* A synthesised voice is a model
  producing audio, so the audit record has to say so — the same requirement D94
  carries for a generated title.

  `absent: NarrationSynthesizer` (D91).

- **D102 — a recorded take OVER-DUBS the microphone; the third track is for
  synthesis.** Requested 2026-09-15 after using the app, amending D93. **Built
  2026-09-15.**

  *The reversal, in the product-owner's words:* "it's overly complicated to
  have a third audio track for voiceover. Recording voiceover should over-dub
  on the microphone lane… Save the third (blue) audio track for voice
  synthesis."

  *Why D93 was wrong, now that it exists.* A third lane carries one kind of
  thing, has a mute and a gain nobody wants to set separately, and puts three
  audio sources in the mental model of a recording that has two. The teal track
  survives, reserved for D101 — a synthesised voice genuinely is a separate
  voice, because nobody ever spoke it.

  *§4.5 is untouched, and that is what makes this possible.* `capture.mov` is
  still never written. A take is its own file, and the exporter ASSEMBLES the
  microphone from both — captured audio where no take covers it, take audio
  where one does. Deleting a take brings the original microphone back because
  the original was never overwritten.

  *`MicrophoneTimeline` is the piece D93 never needed.* A third track was
  simply added alongside; a take has to be woven into an existing one, so
  something has to decide second by second which source the microphone is. It
  returns pieces that TILE the kept footage — no gaps, no overlaps — which is
  the invariant that makes deleting a take restore rather than leave a hole.

  *Several takes, and a later one wins.* Punching in twice is the ordinary case
  once punching in once is possible; fixing two sentences should not mean
  re-recording everything between them. Where two overlap, the second attempt
  is the one that was meant.

  *Old documents DISCARD their narration* (product-owner's choice). A migration
  would have to decide, on the author's behalf, that narration recorded to sit
  BESIDE the microphone should now silence it — the two models place audio
  differently. The audio file stays in the bundle, so the decision is
  recoverable; the lane goes with the narration, because an empty lane claiming
  a track exists is worse than no lane.

  *The transcript is where this is lossy in a way D93 was not.* Under a third
  track both voices were audible and both belonged in the transcript. A take
  replaces, so the capture's words underneath it are removed — keeping them
  would put two different sentences on the same second and invite editing
  against audio that no longer exists.

  *A take's words are tagged `microphone`, not `voiceover`*, because that is
  the lane they play on. Teal now means synthesis and nothing else.

  *The transport, requested in the same breath.* A RECORD button beside play
  rather than replacing it, because play still means play while a take is open.
  Pressing record counts in — three beats, ticking, with the play button
  showing the count, and nothing recording or playing until the last one, since
  a count-in that played the video would put the first beat over footage the
  take is not about.

  *Pause keeps the take OPEN.* You stop to think mid-sentence and carry on;
  abandoning the take there would make pause unusable during the one operation
  it is most needed for. Pressing RECORD is what ends it, and it pauses
  playback too — the thing you do next is listen back, and that starts from a
  standstill.

  *So a take is no longer one run.* `OverdubPlacement.segments(runs:)` places
  each stretch separately with CUMULATIVE file offsets, because
  `AVAudioRecorder.pause()` keeps one file open: the audio is continuous even
  when the timeline is not, and nothing stops somebody scrubbing while paused.

  *`OverdubTransport` is a pure state machine* for the same reason
  `MicrophoneTimeline` is pure: four states where two buttons each mean
  something different is not observable from outside a running app, and
  scattered `if isRecording` checks are what nobody can write a test against.

- **D99 — select, move and scale the marker and subtitle overlays in the
  editor.** Requested 2026-09-14. Global first — one position and one scale for
  every banner, one for every caption — with per-item placement as a later
  iteration.

  *Most of the machinery is already the right shape.* `OverlayLayout` is the
  single source every renderer asks: the preview (`OverlayTextView`), the mp4
  burn (`TextOverlayComposition`) and the GIF burn (`TextOverlayFrame`) all
  read their font size, insets and plate geometry from it, and D51's whole
  point was that three renderers of one design must not each decide. A global
  offset and scale therefore go in ONE place, and all three follow — which is
  the only reason this is a feature rather than a rewrite.

  *What has to be decided, and it is not the dragging.* The offset must be
  stored in UNIT terms, not points. `OverlayLayout` already sizes everything
  from `picture.height` so a caption is the same relative size at every export
  resolution; a position in points would mean an overlay dragged while
  previewing a 4K capture lands somewhere else in a 720p export, which is
  exactly the class of defect the layout type exists to prevent. The EDL gains
  a field (additive, `decodeIfPresent`, no schema bump — the pattern `crop` and
  the three `show` flags already follow), and `PassthroughEligibility` needs a
  new disqualifier only if overlays can move without being drawn, which they
  cannot.

  *The harder half is the gesture, not the model.* The preview is an
  `AVPlayerLayer` under a `CALayer` overlay with `hitTest` returning nil —
  deliberately, so it never takes a click meant for the player — and
  `CropDragOverlay` is the precedent for a drag surface that exists only while
  a mode is active. Selection needs the same treatment: live only while
  something is selected, or it swallows scrubbing.

  *Per-item placement is explicitly deferred and is a different shape.* A
  per-marker offset belongs on the marker, not the EDL, and markers live in
  `events.json` — so it lands on the event model, on undo, and on the marker
  editor, none of which the global version touches. `absent: OverlayPlacement` (D91).

- **D98 — replace the CLA with a DCO plus an Apache-2.0 additional grant.**
  Requested 2026-09-14, ranked after the voiceover work. **Built 2026-09-14.**

  *Both of the CLA's stated reasons are dead, which is the finding rather than
  the friction.* `CONTRIBUTING.md` justifies it as existing "so the project can
  relicense in future (a Mac App Store build, or a commercial licence beside
  the free one)". The second was killed by D66 — "there is no licence to
  enforce and no subscription to gate", and free-and-open-source is named as
  part of the differentiator. The first is simply not true: **MPL-2.0 already
  ships on the App Store.** Brave is MPL-2.0 on iOS and Collabora Online is
  MPLv2 on iOS, iPadOS and macOS; Mozilla's own tracking bug on Apple's terms
  notes "it's lucky we aren't GPLed", because the conflict is with the GPL's
  whole-work conditions rather than the MPL's file-scoped ones. Snitt's actual
  App Store blockers are `CGEventTap` and the agent surface (see §13's M8
  bullet), and neither is a licensing problem.

  *DCO alone cannot do it, and that is the usual mistake.* A DCO sets inbound
  equal to outbound and grants nothing extra, so a DCO-only project cannot
  relicense without unanimous permission — exactly what the CLA was avoiding.
  What works is the DCO's own wording: it certifies the right to submit "under
  the open source license indicated in the file", so the project declares that
  licence as a DUAL grant. Rust's formula is the precedent: "any contribution
  intentionally submitted for inclusion in the work by you shall be dual
  licensed as above, without any additional terms or conditions."

  *What it buys, and what it does not.* An Apache-2.0 additional grant means
  the project can ship under other terms without asking anyone, at near-zero
  contributor friction. It is **not exclusive**: everyone gets the same
  permissive rights, not only the maintainer. A CLA is the only instrument that
  makes a closed fork the maintainer's alone — which is a real difference and
  the thing to decide on, not a detail.

  *Scope.* `CONTRIBUTING.md` declares the dual inbound licence, the PR template
  asks for `git commit -s` instead of CLA agreement, and `CLA.md` is retired
  with a pointer explaining what replaced it and why. It binds only FUTURE
  contributions; work already signed under the CLA is covered more broadly
  already, and the maintainer's own code was never in question, so there is
  nothing to reconcile.

  *No absence marker (D91).* The change creates no symbol — it is three
  documents — and a marker naming a file would be checked by
  `PlanClaimsTests.isDeclared`, which greps Swift declarations under
  `Sources/`. It would therefore pass for ever without ever having been true,
  which is worse than no marker at all. `SignOffTests` is what guards it
  instead: the inbound licence lives in prose and nowhere else, so a
  well-meaning tidy of that one sentence would leave every later contribution
  arriving under terms nobody wrote down. It asserts BOTH licence names,
  because a file naming only the MPL has silently reverted the decision to a
  bare DCO — which grants nothing extra and is the usual mistake.

  *As built, four documents rather than three.* `README.md` advertised the CLA
  too, and a partial migration is its own failure: a contributor told in one
  file that there is no agreement and in another that they must accept one
  cannot act on either. `SignOffTests.theCLAIsNotStillRequired` sweeps all
  three entry points for that.

  *Apache-2.0 is referenced canonically rather than vendored.* Shipping a
  `LICENSE-APACHE` beside `LICENSE` would read as "this project is
  dual-licensed", which is false — the OUTBOUND licence is still MPL-2.0 alone,
  and only contributions arrive under both. A URL says the same thing without
  inviting the misreading.

  *Nothing to reconcile, confirmed rather than assumed.* Every commit in the
  repository at the time of the change is the maintainer's own or Dependabot's,
  so no third party ever agreed to the CLA. The tombstone says so, and says
  what would have applied if anyone had.

- **D97 — one title row, and the side panel treated the way Xcode treats
  its inspector.** Requested 2026-09-14 with Finder and Xcode as the reference.

  *What is already true, so the gap is narrower than it looks.* The editor
  window is already `.fullSizeContentView` with `titleVisibility = .hidden`, so
  the toolbar row IS the titlebar rather than a second deck under it, and
  `EditorToolbar` already stacks a document title over a subtitle at the
  leading edge with the panel toggle at the trailing one. The shape is right;
  what it is not is a `NSToolbar`.

  *What that costs, and it is the whole of the request.* A hand-built `HStack`
  standing in for a toolbar does not get the traffic-light inset, so the title
  starts wherever the row starts and the first 78pt are dead space that the
  window's own buttons sit in. It does not get overflow, so a narrow window
  clips controls instead of collecting them into a chevron. It does not get
  the material, the separator, or the scroll-edge effect the system draws under
  a real titlebar, which is most of why Finder's single row reads as one
  surface rather than as a strip of buttons. And it cannot put an item in the
  trailing accessory position, which is where Xcode's inspector toggle lives —
  attached to the panel it opens rather than merely near it.

  *The side panel half.* Xcode's inspector has its own background material and
  a hard separator, and its toggle sits directly above it in the titlebar, so
  the panel reads as a compartment of the window. Snitt's rail is a plain
  `VStack` of accordion sections against the window background, which is why
  it reads as content rather than as chrome. `NSSplitViewController` with an
  `.inspector`-style item is the system route to that, and it also brings the
  divider behaviour and the collapse animation `ResizableDivider` currently
  reimplements.

  *Why it is not a small change.* The toolbar is a SwiftUI view inside an
  `NSHostingView`, and an `NSToolbar` is AppKit — so this is either SwiftUI's
  `.toolbar` with a `WindowGroup` the app does not use, or a real `NSToolbar`
  whose items host the existing SwiftUI controls. Both rework how the editor
  window is assembled rather than how it is painted. `absent: EditorWindowToolbar` (D91).

- *(D93 — record a voiceover after the fact — was BUILT on 2026-09-14. Its
  entry in the decision table records what was decided; the absence marker is
  retired because `VoiceoverTrack` now exists.)*

- *(D89 — the transcript as a timeline lane — was DROPPED on 2026-09-14. What
  shipped instead is better: the timeline already carries a phrase-chip lane
  positioned in output time, and clicking a chip selects that whole utterance so
  Delete cuts it. Its absence marker for `TranscriptLane` is retired
  with it — a D91 marker is a promise that something is still coming, and this
  one no longer is.)*

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
- **M8 (licensing; Mac App Store)** — the licensing half is **contradicted, not
  deprioritized** (D66): there is no licence to enforce and no subscription to
  gate. The App Store half survives on §4.3's own terms — an App Store build
  ships with **input monitoring disabled**, which is a real constraint the spec
  already established rather than a new one. **That constraint now costs more
  than §4.3 knew**: visible clicks and visible keystrokes (D64, D67) both read
  the `CGEventTap`, so an App Store variant would ship without them. Zoom,
  follow-mouse and crop are unaffected — they need no input data at all.

  **Two further costs, found 2026-09-14 and larger than the input one.** D66
  names agentic support FIRST in the combination that differentiates this
  project, and the sandbox breaks it in two places: `snitt setup --apply`
  writes into an agent's own config file outside the container, which a
  sandboxed app cannot do without the user picking that file every time; and
  the CLI ships at `Contents/Helpers/snitt` expecting to reach a `PATH`, which
  an App Store app may not install into. The socket itself would likely survive
  — it lives under Application Support and a process running as the same user
  can reach a container path. **Auto-trim goes too**, since it needs the event
  log to tell thinking from an empty room. What is left is a screen recorder
  with transcript editing, no agent integration and no input-derived features:
  a different product from the one D66 describes rather than a second channel
  for the same one. **The licence is NOT among the blockers** (D98): MPL-2.0
  already ships on the App Store.


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

**S5 — PARTLY ANSWERED 2026-09-08. Registration is solved and was solved
without noticing; disclosure's real problem turned out to be DRIFT, not a
missing artifact.** Every premise below was checked against the code before any
of it was acted on, and three of them had gone stale: the bundle **does** embed
both binaries (`Contents/Helpers/snitt`, `Contents/Helpers/snitt-mcp`),
`snitt setup` **exists** and writes host configs, and the `instructions` field
this section calls "cheap and unblocked" **was already set**. What had NOT been
done is the thing this section warned about in its own text — *"prose drifts
from the flags it describes, with no equivalent [handshake] to catch it"* — and
it had already happened twice over. The instructions still told agents *"Snitt
must already be running... if it is not running there is nobody to start it"*
months after launch-on-demand made that false, so an agent believing it would
refuse to try or ask a person to open an app that opens itself; and the loop
they described stopped at export, never mentioning `snitt_report_input`,
`snitt_crop`, `snitt_trim` or `snitt_auto_deep_trim` — while
`snitt_start_recording`'s own text warned the caller to "expect to crop the
strip out". **So the answer to "does disclosure need an artifact of its own" is
not yet a skill or a plugin: it is a GUARD on the artifact that exists.**
`ServerInstructionsTests` is that guard — every tool the prose names must
exist, every tool in the workflow must be named (adding one to the list forces
a mention), the stale claims are pinned, and the opening must still say what
the server is FOR rather than collapsing into the verb list the tool schemas
already are. **Still open**, and needing a real agent session rather than
reasoning: whether an agent with a registered server and this text actually
reaches for it mid-task, or whether disclosure needs something that arrives
before a tool list does. Original framing kept below.

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

**S6 — ANSWERED 2026-09-08 (see D68). On-device transcription works at this
floor, exposes word-level timings, and runs at 0.05x realtime.** Original
questions kept below for the record.

**S6 — Is on-device transcription good enough, and does it expose word-level
timings?** D62 makes transcription and text-based editing a pillar (D66) and
binds it to **on-device only** — shipping screen-and-microphone audio to a hosted
service would reverse §3 and §5 in the most sensitive way available. So the
feature stands or falls on what the local APIs can do, and three questions decide
its shape rather than merely its schedule:

1. **Which API, at the macOS 15 floor (§4.6)?** `SFSpeechRecognizer` with
   `requiresOnDeviceRecognition = true` is the candidate that certainly exists at
   that floor; newer frameworks may be better but would raise the floor, which is
   a §4.6 decision and not a free one.
2. **Are word-level timings exposed?** This is the load-bearing one. Captions
   need only segment timings, but **text-based editing needs word timings** —
   deleting a phrase becomes a `Cut` over its span, and without per-word times
   there is no span to cut. If word timings are unavailable, D62 collapses to
   captions and the editing half dies with it.
3. **Cost, and when to pay it.** During capture competes with the encoder for
   exactly the resources §12.1's health sampling exists to protect; after capture
   costs the user a wait before the editor is useful. Measure both on a laptop,
   on real screen-recording audio — which is the hard case: compressed system
   audio, a microphone at desk distance, and long silences.

**Accuracy is judged on this project's own recordings, not a benchmark.** The
audio is narration over a demo, not read prose, and a word error rate that is
fine for search may be useless for editing, where a wrong word boundary cuts the
wrong frame.

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
| D30 | ~~Target selection moves to `SCContentSharingPicker`; makes the grant one-time~~ **SUPERSEDED by D33.** Reasoning in `2026-09-02-snitt-design.archive.md` | Collapsed 2026-09-07; reversed once | — | Superseded | see archive |

| D31 | ~~Agent target grants per application bundle identifier, persisted until revoked~~ **SUPERSEDED by D34.** Reasoning in `2026-09-02-snitt-design.archive.md` | Collapsed 2026-09-07; reversed once | — | Superseded | see archive |
| D32 | ~~An *ungranted* agent request returns `consent_required`~~ **SUPERSEDED by D35.** Reasoning in `2026-09-02-snitt-design.archive.md` | Collapsed 2026-09-07; reversed once | — | Superseded | see archive |

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
| D36 | ~~§4.11 uses a cached last-approved target for the hotkey~~ **SUPERSEDED by D42.** Reasoning in `2026-09-02-snitt-design.archive.md` | Collapsed 2026-09-07; reversed once | — | Superseded | see archive |
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

| D57 | **`auto-deep-trim`** — supersedes and specifies D44's `--auto-trim-gaps`. A span is **dead air** only when *all* hold: audio is nothing but background noise, video is pixel-identical, no mouse or keyboard events, no marker, and no subtitle still owed reading time. Exposed as **conservative / default / aggressive** in the app, and as both that preset flag and individual per-criterion flags in the CLI | D44 held this back needing three things — a generous threshold, audio-aware cut points, and frame-change detection as well as input events. This entry supplies all three plus a fourth D44 missed: **subtitles need reading time**, so a span cannot be dead merely because nothing moved while a caption is still on screen (§4.12, D50). **The cheap path was believed to already exist — REFUTED by D59**, which found `HealthSampler` keeps no timestamps and reduces audio to a single whole-capture RMS, so per-span dead-air detection cannot come from it. The original (wrong) reasoning is kept below because it is why this was scoped as cheap:: `HealthSampler` computes per-frame variance *during* the `AVAssetWriter` pass for §12.1's capture health, so frame-change detection can extend that sampling at near-zero cost. Doing it post-hoc instead means a full decode pass of the movie — a real architectural fork, and the reason to decide it before building. **Two cautions.** *Naming was settled before it could reach a user*: an earlier draft said "strict", which reads either as strict about preserving footage or strict about removing it — opposite meanings in a feature whose job is deletion. **conservative** has one reading, and names the axis (how much footage survives) rather than the enforcement. *Agent recordings log no OS input by construction* (D44, D49), so for an agent-driven demo the input criterion is always satisfied and frame-change detection carries the entire decision — which is precisely the case D44 warned would otherwise see one long gap and delete the whole recording. Interacts well with D56 Tier 1: reversible cut folds make an automatic trim inspectable and individually undoable, rather than a bulk edit a user must accept whole. **BUILT, first slice (2026-09-08).** `AutoDeepTrim.deadSpans` evaluates all five criteria on a 20Hz grid and the editor's Auto-Trim menu applies the result as ordinary cuts on the shared undo stack. **The architectural fork was taken the cheap way, deliberately**: it runs over the waveforms, filmstrip, event log and transcript the editor has ALREADY decoded for the timeline, so it costs a pass over arrays in memory rather than the second decode of the movie this entry warned about. The price is resolution — the filmstrip is capped at a few hundred frames, so on a long recording the picture is sampled every few seconds and only generously-sized dead spans are detectable. That is the right trade for the actual job, which is removing the minute somebody spent reading documentation, not the half-second between two clicks; and `FrameActivity` is a separate input to the detector precisely so a higher-rate pass can be swapped in later without the detection logic knowing. **The rule that keeps D44's fear from coming true is asymmetry between the criteria.** Audio and picture are REQUIRED evidence: with no waveform there is no basis for saying the audio was quiet, and with no frame data none for saying the picture was still, so missing either returns NOTHING rather than everything. Input, markers and speech are VETOES: their presence proves life, their absence proves nothing — an empty event log means "input was not logged" at least as often as "nobody touched anything", which is exactly the agent case D44 warned would otherwise see one long gap and delete the whole recording. Re-running proposes nothing already cut. **CLI built the same day**: `snitt auto-deep-trim <bundle> [--preset conservative|default|aggressive] [--min-span S] [--audio-silence F] [--frame-stillness F] [--input-padding S] [--reading-time S]`. The preset is a STARTING POINT each flag overrides rather than an alternative to them — D57 asks for both forms, and making them exclusive would mean anyone wanting "aggressive, but keep two seconds around clicks" has to restate all five values. A distinct verb from `snitt trim --auto`, which is D44's bookend trim and a different operation. **It goes over the socket like every other document verb**, so §4.9's thin-client boundary is untouched: `DeepTrimPreset` and `DeepTrimCriteria` moved to `SnittDocument` for the same reason `CropRect` lives there — they travel over the protocol, and `SnittAutomation` cannot depend on `SnittExport`. The detector stayed put. One difference from the editor's path: with no open document the host has nothing pre-decoded, so it samples the filmstrip itself, at four frames per second rather than the editor's few-hundred cap — nothing here has to stay responsive, and sampling rate is what bounds the answer's resolution. **A design flaw the CLI found on its first real run, which no test had.** Run against a 200-second screen recording it reported "no dead air found" for the whole thing. The recording has ZERO audio tracks, and an empty waveform array was being read as "the audio could not be measured" when it meant "there is no audio" — so the required-evidence guard, which exists to stop D44's catastrophe, silently disabled the feature on exactly the recordings most likely to contain dead air. Silent screencasts are usually agents', and D44/D49 mean those have no input events either, so the picture is the only signal there is. `AudioEvidence` now has three states rather than a possibly-empty array: `silentByConstruction` (no track exists, so "the audio is background noise" is trivially TRUE), `sampled`, and `unavailable` (nothing can be concluded). The editor needs a `waveformsLoaded` flag to tell its own two cases apart. After the fix the same recording trims to 5 / 24 / 29 spans across the three presets. **MCP built the same day**: `snitt_auto_deep_trim`, with the preset and all five criteria, mapping to the SAME request body the CLI sends — asserted by a test, because §4.8's "the CLI and the MCP server must be incapable of diverging" is otherwise a hope about two parsers. The tool description carries the fact an agent most needs and cannot infer: `snitt_trim`'s `autoTrim` is REFUSED on agent recordings for want of input events, and this one is not, because it reads the picture and the audio instead. Without that sentence an agent refused once reasonably concludes automatic trimming is unavailable to it. Verified end to end over real JSON-RPC against a real recording, which is also how the CLI's `AudioEvidence` defect was found | §8, §4.12, §12.1, D23, D44, D49, D50, D56, D59, D62; `AutoDeepTrim.swift`, `EditorWindowController.swift` (`autoDeepTrim`) | Decided (first slice built 2026-09-08) | enhancement-specified-not-yet-scheduled |
| D59 | **M5f is Tier 1 plus zoom/snapping; slice, reorder, per-track cuts and auto-deep-trim are cut from it.** `snitt trim`'s cut-discarding is fixed first, as its own change | A six-persona refinement pass, run before any of the plan was built. Four personas independently found it reached too far past Tier 1, and **D56's own text already said so** — "nothing about which comes first should be decided before someone has trimmed a real recording" — which my plan bundled past anyway, reproducing D52's pattern one layer inside D58's exception to it. Two task premises were refuted outright: `KeptRanges` sorts cuts and walks a forward cursor, so it **cannot express segment order at all** (slice/reorder is a schema *and* algorithm replacement, not a builder change), and `HealthSampler` keeps **no timestamps** with audio as a **single whole-capture RMS**, so per-span dead-air detection is impossible from it — the opposite of D57's "the cheap path already exists". **Zoom and snapping were added**, because the plan missed what `TrimGesture`'s own comment identifies as the real obstacle: at ~0.75s/pixel on a ten-minute recording "a deliberate short cut is silently swallowed", and folds make density *worse* by packing kept footage into fewer pixels. A plan for "the UI does not suck" that never changes x-per-second was solving the wrong problem | §4.4, §13, D52, D56, D57, D58; `KeptRanges.swift:13-42`, `HealthSampler.swift:26`, `TrimGesture.swift:44-56` | Decided | plan-reached-past-its-own-evidence-gate |
| D60 | **`snitt trim` must preserve existing cuts**, and `edit.json` gains an enforced `schemaVersion` gate | Found by refinement, not use, and it is a **live data-loss bug in shipped v0.1.0**: `EditDecisionList.trimmed(keeping:duration:)` builds `var cuts: [TimeRange] = []` from scratch and returns it, so `existing.cuts` is read and discarded — make interior cuts in the editor, run `snitt trim`, they are gone. `autoTrimCuts` does the same. §4.8 and §6 hold that the CLI and GUI are one model, not two; a CLI that silently deletes the GUI's edits is two. Separately `schemaVersion` is declared on both `EditDecisionList` and `RecordingMetadata` and **compared nowhere**, which matters because D54 makes updates hand-delivered, so old and new builds coexist on one machine and `edit.json` is the only place cuts live — an old build partially decodes a newer file and the next write destroys what it could not represent. Gate the version loudly, test migration against a **real captured v0.1.0 bundle** rather than a remembered literal, and record the schema in diagnostics so "my cuts disappeared" leaves evidence | §4.8, §6, §7, §12, D54; `EditDecisionList.swift:70-77`, `AutomationHost.swift:390-400` | Decided | cli-and-gui-quietly-disagreeing |
| D61 | **The v0 gate has not opened.** v0.1.0 is built, notarized and publishable, but has been handed to nobody; it opens when someone other than the maintainer uses it | Correcting a framing D52 and D58 both rest on. Shipping the artifact proved the *release pipeline* — notarization, stapling, EdDSA signing, appcast generation, all verified end to end, and worth having done — but §13's two questions need users, and there are none. The practical consequence is that "queued pending evidence" (D55, D56 Tier 2, D57, M5d, M5e) has been accumulating against a signal **nobody is collecting**, which makes it deferral without a resolution date rather than evidence-gated sequencing. The maintainer's call: get the UI good enough to hand over first. That also retires the pending 0.1.1 hand-delivery and D54's update-hosting question — neither matters until there is a recipient | §13, D52, D54, D58; direct product-owner correction 2026-09-06 | Decided | mistook-publishable-for-published |

| D58 | **M5f — the editor — is built before validation is judged**, ahead of M5d and M5e. Bundles D55, D56 (both tiers) and D57 | The product owner's judgement after v0 shipped: *"Nobody will like this if the UI sucks."* That is D45's argument applied where I had failed to apply it — I used it to justify the app shell gating v0 (testing with a UI you do not intend to keep risks a "no" indistinguishable from a real one) and then queued the editor work behind evidence anyway. §13's first validation question asks whether anyone prefers this trim/export loop to `Cmd+Shift+5`; a timeline that shows source duration, draws cuts as irremovable overlays, and cannot separate selecting from cutting is not that loop, so a "no" from it would measure the UI rather than the premise. **This is a deliberate exception to D52, not a repeal of it**: D52's rule was that milestones stop being inserted before an *unopened* gate. v0 has shipped, so this is post-gate work being sequenced ahead of other post-gate work, on the strength of the one judgement no review process can supply | §4.4, §13, D45, D52, D55, D56, D57 | Decided | applied-my-own-argument-late |

| D62 | **Automatic audio transcription, and editing through it** — queued as an enhancement, not scheduled | Product-owner direction. Two capabilities that share one mechanism: transcribe captured audio to timed text, and let that text become an editing surface. **On-device only.** macOS ships speech recognition that runs locally, and using a hosted service would reverse §3's "v1 is local-only" and §5's whole posture in the most sensitive way available — Snitt records screens and microphones, so shipping that audio off the machine is categorically different from shipping a crash log. If no local API is adequate, the feature waits; it does not go to a server. **The pieces already exist**: `LoggedEvent.transcript` (D50) is the field, `WebVTTChapters` is the sidecar, `Timebase` converts source to output time, and both mic and system audio are captured separately (`captureMicrophone`/`captureSystemAudio`), so speaker separation is free rather than inferred **— CORRECTED by D73: separate at the file level, not acoustically. Recording through speakers puts the system audio into the microphone track too, and the bleed can be louder than the speech**. **What it unlocks is larger than captions.** With word-level timestamps, deleting a phrase in the transcript becomes a `Cut` over its span — text-based editing over the EDL that already exists, which is a far better answer to §1's speed budget than dragging pixels. It also gives D57's `auto-deep-trim` a real signal: "nobody is speaking" is a sharper criterion than an RMS threshold, and D57's audio criterion currently has no per-span data at all. **Unresolved, needs a spike before planning**: which local API, its accuracy on screen-recording audio, whether word-level timings are exposed, and its cost on a laptop while recording versus after | §1, §3, §4.12, §5, D50, D51, D57; `EventLog.swift:34`, `WebVTTChapters.swift`, `CaptureSession.swift:7-8` | Decided (queued) | field-exists-mechanism-does-not |

| D63 | **Agent-facing discovery gets a spike (S5) before M5e is planned.** The question is not whether to build an MCP server — one exists — but **registration** (the binary is on the machine and the host can launch it) and **disclosure** (an agent thinks to reach for it). Separately, and not an open question: the shipped bundle carrying neither client binary is a **defect**, not one of the options | Product-owner direction: agents need to be told Snitt exists. Verified while framing it: `Scripts/make-app.sh` copies `SnittApp`, `Sparkle.framework` and `AppIcon.icns` into `Snitt.app` and nothing else, so `snitt` and `snitt-mcp` live only in `.build/` on the machine that compiled them — the entire agent surface §13's second validation question depends on is absent from the artifact that was notarized, signed and released. No script installs them anywhere either. That is D61's shape one layer down: the pipeline was proved, the capability was not delivered. **Why a spike rather than a task:** the two problems have different answers and the cheap-looking one is the wrong one. A tool list is read at *call* time and answers "how do I invoke this"; nothing in it answers "why would I record my screen," which is read at *decide* time — so registering the server may satisfy registration and leave disclosure untouched. The reverse also holds: a skill can describe a workflow perfectly and still name a binary that is not there. Weighing them needs the options laid against both axes, which is what S5 does. **One item needs no spike and no waiting:** MCP's `initialize` result has an `instructions` field for server-level purpose and `snitt-mcp` does not set it | §4.8, §6, §8, §10, §13, §14, D52, D53, D54, D61; `Scripts/make-app.sh:150-170`, `build/Snitt.app/Contents/MacOS/`, `Sources/snitt-mcp/main.swift:146-150`, `MCPBridge.swift:110-250` | Decided (spike queued) | capability-built-shipped-nowhere |

| D64 | **Crop, per-segment zoom + follow-mouse, visible clicks and visible keystrokes** — queued, and they **re-scope M6/M7 rather than joining them**. Crop is unblocked today. The other three are blocked on **capture-side data that is not recorded**, not on a renderer | Product-owner direction. The framing to correct first: these read as overlay features, so they look like M7 ("custom compositor + overlay rendering", conditional on M6's desirability probe). **Amended (refinement, 2026-09-07): the mechanism below is wrong for two of the

| D78 | **Visible clicks are BUILT, for REPORTED input only** — burned into mp4 via an export-only animation tool and drawn into GIF frames directly, both from one geometry. D64's window-frame track remains a prerequisite for OBSERVED clicks and for nothing else | D64 held all three overlay features behind "capture-side data that is not recorded", and §13 sequenced the window-frame track ahead of visible clicks on that basis. Half of that turned out to be already false: `InputEventMonitor` records observed clicks with **no coordinates at all**, so those genuinely need the frame track — but reported input (D72) has carried *a fraction of the recorded window* since the day it shipped, which `LoggedEvent` itself describes as "exact forever" and "multiplies straight into video coordinates at any export scale". So the recordings that most need visible clicks — an agent's, where every click is reported precisely because it never reached the screen — could have had them all along. **Position comes from the builder's own `CGAffineTransform`, not a reimplementation.** §9 names re-derivation as the reason position-critical overlays drift: "a preview overlay and an export burn would each reimplement that math". `CompositionBuilder.renderTransform` is now extracted and carried on `BuiltComposition`, so both draw sites apply the transform the picture itself moved by. **Two paths, because one mechanism does not cover both formats**: mp4 goes through `AVVideoCompositionCoreAnimationTool` on an EXPORT-ONLY copy of the composition — V5 still holds, `animationTool` cannot be used with `AVPlayerItem`, so setting it on the shared object would break preview to decorate the export — while GIF draws into each decoded frame, because `AVAssetImageGenerator` ignores `animationTool` entirely and a burn that silently did nothing for GIF is the failure worth avoiding. **Marks belong to a BUILD, not to an export**: both size ladders rebuild at smaller scales, and a mark placed for the full-size frame lands somewhere else on a scaled one — caught while threading the flag, not by a test. **Verified in pixels rather than reasoned about**: both formats render a real file which is then read back and searched for the brightest pixel, because a y-flip passes every arithmetic test and puts every ring in the wrong half of the video. Mutation confirmed exactly that — removing either flip fails only the rendering test. Off by default (`--clicks`, `clicks: true`): a recording's clicks are data (§4.5), and drawing them is a choice | §4.5, §9, §13, D51, D64, D72; `ClickOverlay.swift`, `CompositionBuilder.renderTransform`, `MovieExporter`, `GIFExporter` | Decided (built) | half-the-prerequisite-was-already-there |

| D79 | **An automatic fold carries words: `Cut.label`, derived from the markers around it** — "waiting for build — 4m 12s" rather than a nameless band. Hand-made cuts stay unlabelled | Came from a competitive-analysis pass run in a parallel session, which proposed "auto-fold dead time" as a killer feature. **That part was already shipped** — D57 deep trim, across editor, CLI and MCP — and the proposal's grounding described D44's BOOKEND trim by mistake. What survived the correction is the half nobody had built: D57 leaves *anonymous* holes. `Cut` carried `id` and `range` and nothing else, so an automatic trim produced a timeline of gaps a viewer had to expand one at a time to understand, which is most of the time the trim just saved. **The markers are what make it possible and also why it cannot be copied.** Every competitor's equivalent is audio-driven — Descript shortens word gaps and strips fillers, Screen Studio cuts by hand, Cap has no auto-cut — and all of them assume narration. Snitt's flagship recordings are silent agent sessions with no mic and no system audio, where every existing technique is structurally inapplicable; what those recordings DO have is semantic markers an agent wrote as it worked. **Which marker**: one inside the span first (it describes the removed material directly), then the last one before it (what was happening when the gap began, and the usual case). An automatic trim never folds over a marker — markers veto dead air in D57 — so the inside case only arises for a hand-made cut. With no labelled marker, the duration alone: less than the feature promises, and the honest answer rather than an invented description. **Unlabelled by design for a manual cut** — the person knows what they removed, and describing their own edit back to them would be putting words in their mouth. `label` decodes with `decodeIfPresent` and encodes with `encodeIfPresent`, so every bundle written before today still opens and no `"label": null` appears in a file people read by hand (D60, D54). Drawn only inside an EXPANDED fold band: a collapsed fold is two pixels wide, and expanding one is the gesture that means "tell me what was here" | §4.5, D44, D50, D54, D56, D57, D60, D66, D78; `FoldLabel.swift`, `EditDecisionList.swift`, `TimelineView.swift` | Decided (built) | a-hole-says-nothing-about-what-was-in-it |

| D80 | **Export gains a RESOLUTION knob and a pre-flight menu**: `--resolution 1080p|720p|540p|480p|2160p|source` plus `snitt estimate`, which prices every resolution at once. No bitrate knob — `AVAssetExportSession` has no `videoSettings`, so one would mean replacing the export path with `AVAssetReader`/`Writer` | Product-owner direction, arriving mid-flight on a pre-flight-estimate feature and improving it. **Named by pixels, not by destination**: "1080p" rather than "Social Media", because every platform's limit moves and none of them is Snitt's to track, while the number is what an agent fitting an attachment limit can actually reason about. **Resolution rather than more `--scale`, because scale is not monotonic in size** — measured on a real 5K recording, exporting at scale 0.5 produced a LARGER file (176.6MB) than scale 1.0 (120.3MB), so someone shrinking to fit a budget got the opposite. Resolution presets are monotonic and a test pins that. **The estimate took three wrong turns worth recording.** Scaling the source bitrate by duration and pixels: 0.55-0.67x of actual at full scale, 0.15-0.25x at half, because H.264 does not trade pixels for bits linearly. Encoding the opening two seconds and extrapolating: passed every synthetic test, then estimated 10.6MB for a real 200s recording that exported to 176.6MB — synthetic fixtures are uniform, so none could surface that a screen recording opens on a static page. Three sampled slices in separate exports: still 36% under, because rate control differs between a 2s job and a 200s one. One encode of a composition holding only the sample windows finally bounded it at 1.9x — **and then `AVAssetExportSession.estimateOutputFileLength` turned out to have been there the whole time**, instant and monotonic across presets. I built the probe without first checking what the framework offered; it is deleted. The native ceiling is looser (about 4x on that recording) and that looseness is printed on every row, because a ceiling that reads as a prediction is one somebody sizes an attachment against; `--max-size` remains how to FIT a budget, since it fits by measuring. **A defect the knob exposed**: `ExportManifest` took its dimensions from the composition's `renderSize`, but a resolution preset resizes AFTER that — a 720p export of a 5K recording reported 4112x2580 for a file that is 1280x804. The manifest is what an agent quotes to describe a demo it cannot watch, so it now reads the written file | §4.8, §9, D62, D66, D78; `ExportResolution.swift`, `ExportEstimator.swift`, `MovieExporter.swift` | Decided (built) | the-framework-already-answered-it |

| D81 | **A recording carries the words its transcription should expect** — `vocabulary` on `StartOptions`, stored in `RecordingMetadata`, handed to `SFSpeechRecognitionRequest.contextualStrings` | From a competitive pass: Screen Studio ships a transcription Prompt field for biasing recognition toward product names. The equivalent here is sharper, because Snitt's narration is dense with identifiers no general model has heard — `KeptRanges`, `SCContentSharingPicker`, `edit.json` — and every one the recogniser mishears is a correction somebody makes by hand. D62 shipped the correction UI; this is the other half, telling the recogniser what to expect BEFORE it guesses. **Supplied at record START, not at transcription time**, because that is when the caller knows: an agent about to demonstrate `KeptRanges` knows it is going to say "KeptRanges". **Stored on the RECORDING rather than in a setting**, because the vocabulary that matters is the one this session was about — a demo of `KeptRanges` and a demo of `SCContentSharingPicker` need different hints, and a global setting would carry the wrong one into both. It also survives re-transcription, which is when a better hint is most wanted, since a re-transcription usually happens BECAUSE the first attempt got the names wrong. **Biases without restricting**, so a term never spoken costs nothing and listing generously is the right instinct; the failure mode is an unbounded list rather than an over-broad one, since `contextualStrings` is documented as a hint and not a dictionary — capped at 100 terms and 60 characters each, with the count dropped reported rather than truncated in silence. Terms are trimmed and de-duplicated case-insensitively while KEEPING the caller's spelling, so a transcript reads the way they write. **Not built**: deriving the vocabulary automatically from the repository Snitt already records (§7). That is a bigger feature and a guess about which symbols matter; an explicit list is what was asked for and what a caller can be sure of | §7, D50, D62, D66, D68; `Vocabulary.swift`, `Transcriber.swift`, `RecordingMetadata.swift`, `MCPBridge.swift` **Editable and re-runnable from the editor (2026-09-09)**: the transcript pane carries a "Refine transcription" disclosure with the recording's own terms loaded into it — a blank box would invite retyping what the recording already knows — and a Re-transcribe button. Terms are persisted BEFORE the recogniser runs, so an attempt that is closed or crashes mid-run still leaves the recording knowing what it was asked to expect. **Re-transcribing DISCARDS in-place corrections and says so before the button is pressed**, because a corrected word is marked only by `confidence == 1.0`, which a confident recognition also produces — there is no way to tell them apart and keep one. Undo is the whole answer: the previous transcript goes on the shared stack before the new one lands | Decided (built) | telling-it-what-to-expect-beats-correcting-it-after |
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

| D65 | **PARTLY SUPERSEDED by D66** (its list of "differentiators" named features that are individually table stakes; the framing below stands). **The maintainer is the primary customer, and "queued pending evidence" is retired as a category.** Work is now sequenced by *differentiation* — how much a feature makes this better than the alternatives its author rejected — not by waiting on external validation. §13's two questions survive as questions, but they no longer gate | Product-owner correction: *"I am the primary customer... I am building this for me — because I don't like the other available options... we don't need to wait for people to use it if even I don't like it yet."* This resolves, rather than contradicts, what D61 had already found: queued items were accumulating against a signal **nobody was collecting**, which made "evidence-gated" indistinguishable from "deferred indefinitely". The signal exists and always did — it is the author's own use, available at zero latency, and it is a *better* instrument than five strangers for the question actually being asked, which is whether this is worth using instead of the tools they already rejected. **What this repeals:** the deferral half of D52, D55, D56 (Tier 2), D57, D61, D62 and D64 — every "queued pending evidence" status becomes queued pending *priority*. **What it does not repeal:** D52's mechanism, which was never really about users — it was that a milestone gets inserted ahead of others on a good local argument, and the fix is an explicit priority order rather than a gate. Nor does it touch the evidence standard for *facts*: claims about the code are still verified against the code, and this project's recurring defect has been plans resting on capabilities that turned out not to exist (D59's `KeptRanges`, D59's `HealthSampler`, D64's own follow-mouse mispricing three paragraphs up). Whose judgment orders the work has changed; what counts as a checked fact has not. **The reprioritization this forces:** the differentiators are the editor (D56), automatic zoom/follow-mouse and visible clicks (D64), transcription with text-based editing (D62), and `auto-deep-trim` (D57) — the features that make this unlike `Cmd+Shift+5`. Against them, several built or scheduled items serve a distribution that does not exist and should not consume another hour until it does: **update hosting** (D54 — a private repo, one machine, and `git pull && ./Scripts/make-app.sh` is already a faster update path than Sparkle), **M8 licensing and the Mac App Store variant**, and the parts of §12 and crash reporting that exist to hand a stranger something to attach to a support thread. Notarization, signing and the diagnostics that are already built stay — they are sunk, they cost nothing to keep, and TCC grant stability depends on the signing half | §1, §2, §13, §12; D45, D52, D54, D55, D56, D57, D58, D61, D62, D64; direct product-owner correction 2026-09-07 | Decided | gate-built-for-an-audience-of-one |

| D66 | **The differentiator is the COMBINATION, not any feature in it: agentic support, transcription, focused in-app editing, on-device, and open source (free, no subscription).** Supersedes D65's list of "differentiators", which named features that are individually table stakes | The refinement pass asked what the maintainer's own rejection of existing tools was actually about, because the feature-by-feature answer came back negative: CleanShot X already ships click highlighting, keystroke display and cursor-following zoom; Screen Studio's entire positioning is automatic cursor-follow zoom; Descript popularized transcript-based editing. Against `Cmd+Shift+5` those are differentiators, and §13's original framing measured against `Cmd+Shift+5` — but the field a tool is judged against is the one its user actually chose between, and that field is paid, closed, and mostly subscription. **Answered directly by the product owner:** *"The reasons no existing software is good enough are the combination of: agentic support, transcription, focused in-app editing (trim, cut, etc), on-device, and open source (free, no subscription)."* That is a coherent and checkable thesis rather than a preference — no competitor pairs an agent surface with local transcription, and none is free and open source. **What it changes.** (1) The two members with a real moat are the **agent surface** (§4.8 — no competitor has one at all) and **on-device transcription** (D62 — Descript is cloud, which also violates the on-device pillar), so those rank above the visual-polish features. (2) The polish features are still worth building: matching table stakes is what makes a tool usable by its author, and D58's rule stands — nobody likes it if the UI is bad. They are just not the reason it exists. (3) **M8 is contradicted, not deprioritized**: there is no licence to enforce and no subscription to gate. (4) **Update hosting (D54) is unparked by the same pillar it was parked under** — the appcast 404s only because the repo is private, and "open source" resolves that; the mechanism is already built and correct. (5) Choosing a licence becomes a small unblocking task rather than a milestone, because the repo is private today *precisely* because the licence is unsettled | §1, §2, §4.8, §13, §16; D54, D57, D58, D62, D64, D65; product-owner statement 2026-09-07; competitive check labelled PLAUSIBLE (web-sourced) | Decided | measured-against-the-wrong-field |
| D67 | **Visible keyboard input is BLOCKED on §5.6, not merely deprioritized** — and §5.6 now exists: rendering captured input is off by default, renders key *chords* only when on, and needs a separate per-recording opt-in for the literal character stream | Found by two personas independently, from different mandates. D64 said keystroke rendering "needs a §5 rule of its own before it needs a renderer" — a **policy** gap. D65 then repealed "the deferral half of D64" in bulk, which does not distinguish a policy gap from an evidence gap, so on the spec's own text the feature silently became ready-to-build; D65's own differentiator list dropped it with no stated reason, leaving it genuinely ambiguous whether that was deliberate. **Verified:** §5's five subsections all governed *capture* consent and contained no rule about *display*. The harm is asymmetric with everything else in §5 — a capture stays in a bundle on one machine, a render travels with the export — and this project has already had the incidental-exposure incident (D29, a Mail password notification in the first real M1 recording), whose fix (window-scoped capture) does nothing against an exposure Snitt draws itself. §4.5's reversibility promise likewise protects the source, not a viewer who already received the file. macOS's secure-input suppression covers password fields and nothing else, which excludes every way a secret actually reaches a developer's screen: pasted into a terminal, echoed by a shell, typed into an editor | §4.5, §5.6, §13, D29, D64, D65; Red-team + Product/UX personas, convergent | Decided | policy-gap-repealed-as-if-it-were-an-evidence-gap |

| D68 | **S6 is answered: D62's text-based editing is buildable at the macOS 15 floor.** `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` transcribed a real recording with **per-word timestamps, durations and confidences**, at **0.05× realtime** (0.98s for 20.9s of audio). No §4.6 floor change is needed, and D62 proceeds as the full feature — transcript-as-editing-surface — not captions-only | Run against the maintainer's own first voiceover recording, which is the hard case S6 named: a desk microphone, natural pacing, long silences. **CORRECTED 2026-09-08:** this entry originally read "speech starts at 11.28s of a 20.9s recording" and offered that as evidence the recognizer handled a long silent lead-in. It was not silence — it was the first half of the narration, LOST. `SFSpeechRecognizer` segments file audio at pauses and its single `isFinal` result carries only the **last utterance**; partial results carry the running text but report every timestamp as 0. The conclusion below survives intact (word-level timings exist on-device and are usable), but "handles the hard case" was a misreading of a defect, and on a ten-minute demo the same defect would have kept only the closing sentence. Fixed by transcribing per utterance (`SpeechChunker`), which recovered the recording's full 33 words starting at 1.70s — and improved the text, since each utterance is now recognized whole rather than as a fragment. Every segment is a word (16 segments, distinct increasing timestamps, real durations); confidences degrade honestly on proper nouns ("loom is" at 0.34 for what was probably "Loom is" — the transcript will need correction, which the D50 marker-edit surface already provides). **The cost number changes the design**: at 0.05× realtime there is no reason to transcribe during capture — after-capture is 1s for a 20s recording, competes with nothing (§12.1's concern evaporates), and can simply run when the editor opens. **Two facts for the implementation, learned the hard way**: `capture.mov` carries audio as [systemAudio, microphone] and a recogniser takes the FIRST track, which for a mic-only recording is pure silence returning a confident empty transcript — the mic track must be extracted explicitly; and Speech Recognition is TCC-gated with the grant attributed to the requesting process, so Snitt.app needs its own `NSSpeechRecognitionUsageDescription` and prompt (§4.10's ladder gains a rung, requested at first use of transcription, not at launch) | §3, §4.6, §4.10, §5, §12.1, §14 (S6), D50, D62, D66; probe run 2026-09-08 on `Snitt-1788888317.snitt`; `Spikes/S6TranscriptionProbe/` | Decided | spike-answered-by-the-first-real-recording |

| D69 | **An agent must name WHICH window; ambiguity is refused, not guessed.** `StartOptions`/`snitt_start_recording` gain `windowID` (from `listTargets`, transient — never stored, so V10's ban on persisted ids stands), and the agent path throws `ambiguousWindows` listing the candidates when an application has several recordable windows and nothing chose between them | **Found by the first real agent-driven recording**, which is the evidence §13's second validation question was waiting for. An agent asked to record Chrome with ten windows open; `CachedTargetResolver.bestMatch` returned the LARGEST, and Snitt silently recorded a private pull-request diff instead of the intended demo. Nobody could have known until watching it. **The old rule was defensible where it was written and wrong where it was used**: its comment says "recording the right app beats recording nothing", which holds for a human pressing a hotkey with a remembered target — but `cachedResolverFactory` has exactly one production caller, `startForAgent`, so in practice it only ever served the path where nobody is watching. §5.1 makes window-scoped capture the default precisely to avoid incidental exposure; choosing arbitrarily among an app's windows reintroduces it. **Three things this reveals about the surface**: `TargetSummary` already carried the window `id`, so the agent HAD the answer and had no field to return it in; `titleHint` exists in `TargetReference` documented as "kept only to disambiguate when one app has several windows" and the agent path always passed `nil`; and §8 has documented `snitt record start --window-id N` since the API was specified, unimplemented until now. The design anticipated this and the wiring was never finished | §4.9, §5.1, §8, §13, V10, D42; `CachedTargetResolver.bestMatch`, `AutomationHost:751`, `TargetSummary.id`; agent recording 2026-09-08 | Decided | anticipated-by-the-design-never-wired-up |
| D72 | **A client may REPORT input the OS never saw** — `snitt_report_input` / `snitt record click`, position as a fraction of the recorded window, marked `reported` and distinguishable from anything observed. This is not a reopening of D49: nothing is posted, no Accessibility grant is involved, and the caller has already done the thing it describes. Snitt is recording, which is its job | Product-owner direction, from watching agent recordings. Browser automation dispatches into the page — `element.click()`, CDP's `Input.dispatchMouseEvent` — so the real cursor never moves and nothing reaches the `CGEventTap`. The recording shows buttons changing state with nothing visibly causing it, which is precisely what makes an agent demo unwatchable, and it is invisible to every input-driven feature: D64's visible clicks have no positions, `auto-trim` sees no events and refuses, and `inspect` reports zero input for a recording full of it. **Provenance is the load-bearing part.** `autoTrimRange` treats every non-marker event as evidence of activity and `InspectReport` publishes a count; without a source field, "a person clicked here" and "an automation asserts it clicked here" become the same claim and the recording vouches for input it never saw. `EventSource` separates them, `inspect` publishes `reportedEventCount` beside the total, and absent means `observed` — the historically true answer for every file written before the field. **Two refusals worth stating.** A reported KEYSTROKE is rejected outright: a click is a claim about what the caller itself did, a keystroke is a claim about what a person typed, and §5.6 governs rendering those precisely because they are the dangerous ones. And a reported click is stripped of its label by the same boundary that strips an observed one — an agent naming what it clicked would put click content into a plaintext file that travels with the bundle, and a well-meaning caller is not a reason to trust it; narration already has a home in a marker. **Coordinates are window fractions, not screen pixels**, because screen coordinates need the window's frame at that instant to mean anything and no window-position track exists (D64 names one as a prerequisite and it is unbuilt). A fraction is exact forever and multiplies straight into video space at any export scale. events.json 2 → 3 under D60's gate **AMENDED 2026-09-08: a keystroke may be reported as a CONTENT-FREE BEAT.** The original rule refused reported keystrokes outright, because letting a caller write typed input into a recording is "a claim about a person rather than about itself". That reasoning is about CONTENT, and it survives intact — a reported keystroke carrying a label is still refused, by the host and by the MCP bridge, with a message saying why. What it no longer blocks is the TIMING. A beat says "I typed at this instant", which is exactly the claim `cursor` was already trusted to make, at the same level of trust and with the same `reported` provenance; it adds no new class of assertion. **Why it had to change:** `autoTrimRange` finds a recording's bookends from input events and reads nothing but their timestamps, so an agent driving a TERMINAL could not auto-trim at all — it produces no clicks, and markers deliberately do not count. Reported keystrokes also feed D57's veto criterion. `x`/`y` are nil rather than zero for a keystroke, because zero is the window's top-left corner and a keystroke happened at no corner. Reachable as `snitt record keystroke <session>` and as `snitt_report_input` with `kind: "keystroke"` | §4.2, §5.1, §5.6, §7, §12; D44, D49, D53, D60, D64; agent recording sessions 2026-09-08; §4.8, §5.6, D44, D49, D57, D67; `AutomationHost.reportInput`, `MCPBridge`, `EditDecisionList.autoTrimRange` | Decided (amended) | recording-what-the-OS-cannot-see |
| D70 | **OPEN — needs a ruling.** §5 governs WHICH window is captured and says nothing about what is inside one, so a window's own chrome is an unexamined exposure surface. A browser tab strip renders the titles of every other open tab into every frame. **Shipped now** (no principle at stake): `snitt_start_recording`'s description and the CLI usage say so outright. **Not decided**: whether capture should be able to EXCLUDE part of a window | Found in the second agent-driven recording session. The agent went to record a Chrome window and noticed it also held a Namecheap order confirmation and a Carta login, whose titles would have been on camera; it spent several steps moving the page into its own window to avoid that. It reasoned correctly and unprompted — the next one may not, which is why the warning shipped immediately. **The symmetry with D29 is the point.** §5.1 exists because a "Mail Password Required" notification appeared during the first M1 recording: something ELSE intruding on screen. This is the same harm from the opposite direction — the target window itself carrying other people's secrets in its chrome — and window-scoping, the fix for the first, does nothing for the second. **The open question and its cost.** `SCStreamConfiguration.sourceRect` can restrict what is captured at all, so a tab strip never enters `capture.mov`. That is a strictly stronger guarantee than cropping at export (D64), because the BUNDLE stays clean — which matters the moment a `.snitt` is shared or kept rather than only its export. But it runs directly against §4.5's *pristine capture, non-destructive edit*: it is irreversible by design, and that is precisely why it is stronger. The two principles genuinely conflict, and the resolution is a product call rather than an engineering one. Options as they stand: leave it (crop covers the export path and nothing else), allow an explicit capture-time rect for agent recordings only, or allow it everywhere with the irreversibility stated at the point of choice. **RULED 2026-09-08: leave it, and build it if it is asked for.** The warning that shipped is the whole of the response for now — an agent is told what a window includes and can move a page to its own window, which is what the one agent that met this did unprompted. **Trigger to reopen:** somebody wants a bundle they cannot share because of what its chrome captured. That is observable in ordinary use and needs no separate watch, which is what makes this a deferral rather than an indefinite one (D65) | §4.5, §5, §5.1, §7, D29, D64; agent recording session 2026-09-08; `SCStreamConfiguration.sourceRect` unused in `Sources/SnittCapture/` | Deferred (2026-09-08) | scope-rule-that-only-looked-outward |

| D71 | **OPEN — D49's revisit gate is satisfied, on a fact rather than a preference.** D49 rules that Snitt does not drive input, resting on: "posting synthetic events needs an **Accessibility** grant, the most powerful TCC permission on the machine, and it would mean a prompt-injected agent could drive the Mac rather than only film it." That is true of `CGEvent.post` and **not true of every way to move a window's content**, so the premise is narrower than the ruling built on it | Second agent recording session: the agent could not scroll the page it was demonstrating, because its own control tool is allowlisted per domain and that domain was not on the list. The video shows the article sitting static for ~20s. **This is a DIFFERENT trigger than the one D49 named in advance** — D49 anticipated "demos are poor because input is not on the recording clock, clicks and their markers drifting apart", and what actually happened is that the agent's control tool could not reach the target at all. The gate still opens, because the qualifying change is new evidence contradicting a fact the decision rested on. **The permission taxonomy, which is the whole argument.** Reading input is Input Monitoring (`kTCCServiceListenEvent`) — Snitt already holds it for §4.2's event log. POSTING input via `CGEvent.post` is Accessibility, and it is **all-or-nothing**: there is no "scroll only" to grant, so D49's fear is exactly right for that route. But **Apple Events scripting is a third thing** (`kTCCServiceAppleEvents`), granted per SOURCE→TARGET application pair, listed in Settings ▸ Privacy ▸ Automation, and revocable per pair. Scrolling a scriptable app through it needs no Accessibility at all. Verified in-repo: Snitt posts no event anywhere today, and `AXIsProcessTrusted` is false, so nothing currently relies on the broad grant. **What a narrow version could be**: `snitt_scroll(sessionId, dy)` that moves only the window already resolved as the recording target, only while that recording is running, and drops a marker at the same instant — which also puts the scroll ON the recording clock, the correlation D53 wanted and the agent's out-of-band tool cannot give. That is "scroll the window you already consented to film, on the record", not "drive the Mac". **Costs, honestly**: it works only for scriptable applications, Chrome additionally requires *Allow JavaScript from Apple Events* to be enabled by hand, and every new capability on this surface widens what a prompt-injected agent can reach — the difference is that this one is bounded by a per-app grant the user can see and revoke, rather than by Snitt's own restraint. **RULED 2026-09-08: agents should handle their own scrolling; revisit only if it proves a real source of friction.** D49 stands as a ruling even though its stated premise was too narrow — the finding below it changes what is POSSIBLE, not what is wanted. **The instance that prompted this does NOT count as the trigger**, and saying so is the point: that agent could not scroll because its own control tool is allowlisted per domain and the domain was missing, which is a gap in the agent's tooling rather than in Snitt's. The trigger is RECURRING friction across different agents and different tools — one blocked domain is not evidence that recording needs a control surface | §4.2, §4.10, §5, §12; D49, D53; `InputMonitoringAccess.swift:11`, no `CGEvent.post` in `Sources/`, `AXIsProcessTrusted() == false` | Deferred (2026-09-08) | ruling-broader-than-the-fact-under-it |

| D73 | **Speaker bleed is a first-class recording hazard, and the silence threshold must be robust to it.** Two separate defects behind one symptom: the chunker measured silence against the *loudest* peak (fixed — it now measures against the 90th percentile), and the microphone track is not acoustically separate from system audio when the recording is made through speakers (not fixable in software at this layer; needs a pre-flight warning) | Found from a real recording the maintainer made, not from review. `Snitt-1788900308.snitt`: 32s, narration over SoundCloud playback, transcript came back with **five words**. The mic track's per-second peaks tell the whole story — `0.01 0.01 0.02 0.07 0.15 0.12 ... 0.02` for the first seventeen seconds (that is the voice), then `2.216` and a sustained `0.48–0.78` for the rest (that is the music, arriving through the air). **Defect one:** `SpeechChunker` set its silence threshold at `loudest × 0.08`, and one clipped instant at 2.216 put that threshold at **0.177 — above almost all of the speech**, so 81% of the file classified as silence, chunk boundaries were placed by the music rather than by pauses, and the recogniser was handed chunks whose content was a song. The relative threshold was itself a considered choice (recording levels vary by an order of magnitude, and a fixed threshold tuned for a hot signal treats a quiet one as silent), and it was mutation-verified — but it assumed *the loudest thing in the mic track is speech*, which a cough, a door, a notification chime or speaker bleed all falsify. Measuring against the **90th percentile** instead keeps the property that motivated the relative design and removes the outlier sensitivity: on this recording the threshold drops 0.177 → 0.023 and the transcript goes from 5 words to 14 (`"Go to SoundCloud Let's find a song to play Let's play this one I can"`). **Defect two is physics and survives the fix:** speech spoken *during* loud playback is masked in the microphone signal itself, so nothing downstream can recover it — which is why the transcript still stops at 15.7s. Recovering it would need the system track used as a reference for adaptive echo cancellation, which is real DSP and is NOT proposed here. **The cheap remedy is headphones, and Snitt can say so deterministically rather than heuristically**: when both `captureMicrophone` and `captureSystemAudio` are on and the default output device's CoreAudio transport type is built-in, bleed is certain, and that is knowable before the recording starts rather than after 32 seconds of unusable narration. **BUILT (2026-09-08)**: `AudioOutputRoute` reads the default output device's transport type and data source, the status menu shows a disabled warning row when a voiceover would be recorded through the speakers, and `CaptureHealth.outputRoute` records the route in the bundle so a poor transcript can be explained rather than merely observed. **The subtlety that makes it a check and not a guess**: a Mac reports headphones in its own 3.5mm jack with the SAME transport type as its speakers, so a check that stopped at the transport would warn at people wearing headphones — the data source (`'ispk'` vs `'hdpn'`) is what separates them. Anything not positively identified stays `.unknown` and says nothing, including external speakers that really would bleed: the OS cannot say whether a USB or Bluetooth device is a headset or a desk speaker, and a warning that is sometimes wrong is worth less than one that is sometimes absent. No dialog and no interruption — §4.11 forbids putting anything in front of the hotkey path, and the intervention is simply telling the truth in the menu at the moment someone is about to record. **What this corrects:** D62 cited separate tracks as making speaker separation "free rather than inferred" — true of the container, false of the air, and the transcription feature was planned on the stronger reading | §4.12, D62, D68; `SpeechChunker.swift` (`referenceLevel(of:)`), `SilenceReferenceTests`; `Snitt-1788900308.snitt` measured 2026-09-08 | Decided (both halves built 2026-09-08) | loudest-thing-in-the-track-assumed-to-be-speech |

| D74 | **A `.snitt` bundle carries its own Finder icon: a frame from the recording under the record dot.** Stamped into the bundle at finalization and refreshed when editing changes what the recording is — NOT a Quick Look thumbnail extension | Product-owner direction. The problem is concrete: every bundle is named `Snitt-<epoch>.snitt` and every one of them carries the same generic package icon, so telling this morning's demo from yesterday's bug report means opening them one at a time. The captured frame is the only thing that distinguishes them at a glance. **Why stamping rather than a `QLThumbnailProvider` extension**, which is the conventional answer: (1) a thumbnail extension is an `.appex`, and SwiftPM does not build app extensions — it would need an executable target relinked with `-e _NSExtensionMain`, hand-assembled into a bundle by `make-app.sh`, and separately codesigned, all before the first pixel; (2) an extension only renders where Snitt is INSTALLED, while a stamped icon travels inside the bundle to any Mac it is copied to — and the whole point of a `.snitt` is being handed to someone; (3) `NSWorkspace.setIcon` on a package writes an `Icon\r` file inside the directory and sets the Finder's custom-icon flag, verified empirically on a real bundle before any of this was designed, and `SnittBundle` addresses its contents BY NAME rather than enumerating, so the extra file is inert. **Design, chosen from rendered candidates against a real recording rather than described**: the frame fills the icon (aspect-fill — letterbox bars in a square icon read as a rendering bug), a scrim darkens the bottom so the badge has something to sit on, and the record dot goes bottom-right. Chrome and wordmarks were both tried and rejected: at 16 and 32 points, where a document icon is actually seen, a slate border is indistinguishable from blur and `SNITT` is unreadable — both spend the pixels that make the picture recognisable. **Two things the implementation had to get right and neither was obvious.** The poster is NOT the first frame: a screen recording opens on a blank desktop or a half-drawn window, so six frames are sampled across the middle 84% and scored by luminance variance at 32x32 — icon resolution deliberately, because that measures the structure that will still be visible in the Finder rather than detail that will not. And the poster is chosen from the material the EDL KEEPS, so trimming a dead lead-in (the single most common edit this app exists to make) moves the poster instead of leaving it in the discarded seconds. **Cost, measured not assumed:** 960ms on a 32s 5K capture, brought to ~500ms by capping `AVAssetImageGenerator.maximumSize` and dropping the exact-frame seek tolerance that bought nothing. Still far too much to sit in front of a recording reporting that it stopped, so it runs off the stop path — which `RecordingCoordinator` already carried a written warning about. Refresh happens once per editing session, on window close, not per edit | §4.5, §6, §9, D56, D60; `RecordingIcon.swift`, `RecordingCoordinator.swift` (stop path), `EditorWindowController.swift` (`teardown`), `Scripts/make-app.sh` (the `com.apple.package` UTI this relies on) | Decided | every-recording-looked-identical-in-the-finder |

| D75 | **Markers get a chapter-index panel on the left of the editor, and the timeline lane STAYS fully interactive.** The panel also becomes the first way to create a marker outside of recording | Product-owner direction, with the additive-vs-replacing question put back to them explicitly and answered "keep the lane fully interactive". The two surfaces answer different questions and neither substitutes for the other: a lane shows **where** a marker falls relative to the waveform and the cuts, and supports drag-to-retime (D56/M5f Task 6) that a list cannot express; a list shows **what** each marker is — its name and its narration — and lets the structure of a recording be read without scrubbing. The cost of keeping both is that markers now have two UIs, which is real but bounded: both read `events` directly, so there is no second copy of the data to drift. **What the panel does**, all four requested: rename inline on double-click, highlight the chapter containing the playhead, add at the playhead and delete, and show each marker's transcript (D50) as an excerpt under its label. **The add capability is the quiet one that matters most.** Until now a marker could only be created by pressing the key DURING a recording, which means an agent's recording — §4.8's whole surface, and D66's first pillar — could never be chaptered at all, and neither could any recording where the moment was noticed a second too late. **The panel REPLACES the bottom jump-point list**, which was a full-width `List` of `Button(point.label)` under the transport controls. It could seek and nothing else, and it spent the window's whole width on what is now a 260pt column — while the labels people actually write are descriptive sentences that the old list showed in full and the first version of this panel clamped to one line. The panel wraps them. **Three hazards the implementation had to handle.** (1) Markers are stored in SOURCE time and the panel navigates OUTPUT time; feeding a view the wrong clock is the exact defect M4b shipped and D56 had to fix. The first version converted with its own `Timebase` call, which was a **third** implementation of a projection that already existed twice — and `MarkerJumpPoints.swift` warns in its own comment that "a chapter list and a scrub bar that disagree about the same recording are worse than either alone". The panel now shares `MarkerTrackPoints.compute` with the timeline lane, so the two cannot drift, and a test asserts they place every marker identically. **The distinction that made this a real choice**: `MarkerJumpPoints.compute` DROPS markers inside cuts and `MarkerTrackPoints.compute` keeps them folded to the cut's edge — the panel needs the second. (2) A marker swallowed by a cut is **listed, dimmed, at the fold**, not dropped — it is still in `events.json` and moving the cut brings it back, so vanishing it from the index would look like the cut deleted it; and because the fold is a real instant, clicking the row seeks somewhere rather than doing nothing. (3) A rename to blank stores `nil`, not `""` — the panel falls back on either, so display cannot tell them apart, but `WebVTTChapters` does `marker.label ?? "Chapter N"`, a nil-coalesce rather than an empty check, so an empty string would export a chapter with **no title**. The test that first covered this asserted only what the panel showed and passed against exactly that bug; it now asserts the stored value | §4.8, §9, D50, D51, D56, D66; `MarkerPane.swift`, `EditorWindowController.swift` (`chapters`, `addMarker`, `deleteMarker`, `renameMarker`, `currentChapterID`), `WebVTTChapters.swift:40` | Decided | lane-showed-where-never-what |

| D76 | **The timeline is a fixed dark surface with an orange waveform, and stops following the system appearance.** Explicit greys replace the semantic `NSColor`s it filled with | Product-owner direction — *"make the audio in the waveform orange to better contrast against the background, also make the background dark grey"* — and behind the request, a real bug. The bands were filled with `tertiaryLabelColor` and the waveform drawn in `labelColor`: **LABEL colours used as BACKGROUND fills.** Label colours invert with the appearance, so under the dark appearance the rest of the window was already using, the audio band rendered as a PALE slab and the waveform — also pale — sank into it. The band was at its least readable in the mode it is actually used in, which is why the fix is not simply a hue change. **Why fixed rather than appearance-aware:** a timeline is a dark surface in every editor that has one, because the content on it — waveforms, thumbnails, cut marks, the playhead — is what should carry the colour. Committing to that also forces the playhead and separators to be spelled out, since on a permanently dark ground a `labelColor` playhead is black-on-black under a light system theme. **Measured, not eyeballed** — three times I read the render wrong (calling `#2A2A2A` band gaps "black") before sampling the pixels, which is the same lesson as every other entry here: mic band `#2A2A2A` under an `#FD7E25` waveform, muted system band `#1E1E1E` under a `#5D3920` one, marker lane `#333333`, video band `#202020`. `NSColor(white:)` was replaced with explicit sRGB after the first pass came out visibly darker than its own numbers. **Clipping stays `systemRed`** and is now adjacent in hue to an orange waveform — the band-edge markers remain the reliable signal, and this is the one part of the change worth revisiting against a real clipped recording. **The test that matters asserts under BOTH appearances**: checking only the current one passes against any semantic colour, since whichever appearance the host runs under gives one plausible answer — and the actual bug, `tertiaryLabelColor` as a fill, is dark under a LIGHT appearance and so survives a darkness check alone | §4.7, D56, D59; `TimelineView.swift` (`Palette`), `TimelinePaletteTests` | Decided | label-colour-used-as-a-background-fill |

| D77 | **The minimum OS is macOS 26 (Tahoe), raised from 15**, and `Package.swift` moves to swift-tools-version 6.2 | Product-owner direction, and the evidence for it arrived the same hour from CI's very first run. **The floor had already moved; the manifest just did not say so.** Pinned to `macos-15` — matching the then-declared `.macOS(.v15)` — the build job failed on the macOS 15.5 SDK with `SCShareableContent` not conforming to `Sendable`, then, once that was patched, on `CIContext` not conforming either. Both types ARE `Sendable` in the macOS 26 SDK. So the package had drifted to depend on a newer SDK's concurrency annotations in at least two frameworks, and no local build could reveal it because every local build ran on 26. **This is exactly what §4.6's kind of decision is not**: 15 was chosen to UNLOCK capability — native microphone capture through one `SCStream`, `SCContentSharingPicker`, and the deletion of a whole hand-synchronisation path. Nothing needs a macOS 26 API. The floor is raised because the alternative was scattering `@preconcurrency` through the codebase to keep a promise already broken, one framework at a time, with CI as the only place the breakage was visible. **The cost is real and larger than 15's**: macOS 26 is a current release, so this excludes everyone not yet upgraded — defensible only because D65 makes the maintainer the primary customer and they are on 26. It should be revisited the moment there is a second user. Asserted in three places that must move together: `Package.swift`, `Scripts/make-app.sh`'s `LSMinimumSystemVersion`, and the CI runner label | §4.6, D65; `Package.swift:1,6`, `Scripts/make-app.sh:78`, `.github/workflows/ci.yml` **A consequence neither the direction nor I anticipated, found by CI again:** raising the floor made 18 deprecations fire in `CompositionBuilder.swift` — the whole `AVMutableVideoComposition` family, superseded by `AVVideoComposition.Configuration`. Deprecations do not fire until the deployment target REACHES the deprecating version, so at floor 15 these were silent; at 26 they are the compiler telling the truth. **Nothing broke** — deprecated is not removed — but the export pipeline is now written against a superseded API, in the one file every export and preview goes through (§9). **Migrated the same day** rather than exempted, so no warning group is excused in CI. `AVVideoComposition.Configuration` describes the same three nested pieces — composition, instruction, layer instruction — as value types that are then made once, so what `BuiltComposition` hands out is immutable instead of a mutable object trusted not to be changed; `setTransform(_:at:)` survives unchanged, which is what kept the transform stack (orient, translate the crop origin, scale) byte-identical. The new API is Swift-only — the ObjC headers name it solely in their own deprecation text — so its shape was learned by probing the compiler rather than read. All 1041 tests pass, including the export suite that encodes real files through this path | Decided | floor-already-moved-manifest-did-not-say-so |

| D88 | **Mute and gain re-apply the audio mix IN PLACE; they do not rebuild the composition** — `applyAndSave(rebuild:)` splits the two, and `PreviewController.applyAudioMix(edl:)` assigns a fresh `AVAudioMix` to the live player item | Reported as "adjusting gain shouldn't reset the playhead to the start", and it did: every EDL edit went through `PreviewController.apply`, which calls `replaceCurrentItem` and so restarts at zero. Correct for a cut, which moves material; pure loss for gain, which changes **nothing else in the build** — mute and gain are expressed only in `BuiltComposition.audioMix`, leaving the tracks, their positions and the duration identical, so the rebuild was wasted work whose only visible effect was the reset. **The failure is worse than an annoyance in the one case the control exists for**: judging a level means listening to a passage, and the playhead left that passage on every tick of the slider. **A nil mix must be ASSIGNED, not skipped.** `audioMix(for:edl:)` returns nil for "nothing to express", and treating that as "nothing to do" leaves the previous mix installed — so un-muting a track would leave it silent forever, with an EDL saying it is fine and a slider reading 1.0. Two tests pin it, including one that interleaves a cut so the mix-only path has to clear a mix a rebuild installed. **The private mix builder now takes `AVAssetTrack` rather than `AVMutableCompositionTrack`**, which is all `AVMutableAudioMixInputParameters(track:)` ever wanted, so the mix can be re-derived from a finished composition. Serialization against the pending save is unchanged: a gain change and a cut both write the whole `edit.json` and must not race. Verified on the PLAYER — where the playhead is and which mix the player holds — because `edl` carrying the right number says nothing about what you hear or where you are; matched by track ID rather than by position, since index-matching audio tracks is the documented bug that once gave systemAudio the state named "video" | §4.8, D56; `CompositionBuilder.audioMix(for:edl:)`, `PreviewController.applyAudioMix`, `EditorWindowController.applyAndSave(rebuild:)` | Decided (built) | changing-a-volume-is-not-a-new-recording |

| D89 | **DROPPED 2026-09-14 — the transcript does NOT become the timeline's primary surface.** Proposed as a full word-level lane replacing the side pane | Product-owner direction, then product-owner reversal once the smaller version existed: "drop D89, the current implementation is superior". **What shipped instead, and why it is enough**: the timeline carries a PHRASE lane (`WordLaneTiers`, `TranscriptPhrases`) positioned in output time so cuts re-flow it, and a click on a chip selects that whole utterance as a `Selection` — so "cut from here to there" IS a text gesture, which was D89's entire argument. **What was dropped is the part that cost the most and bought the least**: word-level density. A minute of speech is ~150 words against ~1000px, so words only fit at deep zoom, and the level-of-detail rule needed to keep them legible is machinery in service of a tier nobody reads at. Replacing the side pane was also the wrong half of the idea — the pane became a timed, divided phrase list in the rail beside the markers, which is a better place to READ a transcript than a 1000px strip. A lane is a map and a pane is a list; the recording wanted both | §4.5, §4.9, D50, D62, D79, D82; `TimelineView.swift` (phrase lane), `TranscriptPane.swift` | Dropped (2026-09-14) | a-list-you-read-versus-a-map-of-the-recording |
| D87 | **Scrubbing stops playback; rewind does not** — every navigation gesture (the timeline lane, a chapter in the panel, a word in the transcript) pauses on the way to its target, and a Rewind button sends the playhead to the start without touching the transport | Product-owner direction, reported as two items ("the UI needs a rewind button", "clicking anywhere in the timeline stops playing"). The scrub half is a correction: aiming at a frame while the picture keeps moving means the frame is gone by the time the seek lands, and the playhead then walks away from where it was just put — which reads as the click having been ignored rather than as playback continuing. **All three navigation paths share `onScrub` deliberately**, because they are the same act with different targets, and pausing only on the lane would make the panes behave differently from the timeline for no reason a user could predict. **Rewind is the exception and is the reason it does not route through `onScrub`**: pressed during playback it restarts the run from the top, which is the replay gesture and the whole reason to reach for it while watching. It seeks the composition at zero rather than mapping through `keptRanges` — zero in OUTPUT time is the start of the edit whatever is cut, so there is nothing to resolve, and the mapping would only be an extra way to be wrong. Both mutation-verified on the PLAYER rather than on calls: `rewind()` written as `onScrub(0)` — the obvious implementation, and one that inherits the new pause — fails `rewindKeepsPlaying`, which counting `pause()` calls would not | §4.5, D56, D75, D76, D82; `EditorWindowController.swift` (`onScrub`, `rewind`) | Decided (built) | a-scrub-aims-at-a-frame-a-rewind-aims-at-a-beginning |
| D85 | **A crop is PROPOSED, then committed** — entering crop mode puts an adjustable bounding box over the whole picture, which drags move and resize until an explicit Apply writes it to the EDL | Product-owner direction ("crop should be a bounding box that can be adjusted before committing to the crop"). The first version applied on mouse-up, which made cropping a single unrepeatable act: the only correction was undo plus a fresh drag, and the box being aimed at had already vanished from the screen. **The proposal lives in the editor view, not the overlay**, normalized to the picture rather than to the view — Apply is a toolbar button that has to read it, and normalizing keeps a placed box where the user put it when the window resizes under it. **The overlay can no longer apply anything**: it takes a `Binding<CropRect>` and has no commit callback at all, so "nothing reaches the EDL until Apply" is a fact about the type rather than a claim a test has to defend. **Entering starts from the full frame every time**, because `applyCrop` COMPOSES onto the existing crop and the preview already shows it — the full frame is the identity, and a leftover box from a cancelled attempt would silently re-propose itself. Apply is disabled at the full frame, since composing it is a no-op and a button that appears to do nothing is worse than one that says why. **Clamping, not flipping, when an edge is dragged past its opposite**, with a 32pt floor: a box that inverts under the pointer is disorienting, and one dragged to zero cannot be recovered because there is nothing left on screen to grab — and the floor yields to a picture smaller than itself, which a narrow window or a pillarboxed portrait recording produces. Moving clamps position without resizing, so shoving the box into a corner does not silently narrow it. All of it in `CropBox`, pure, and mutation-verified against six wrong implementations including a y-flip and an edges-before-corners hit test | §4.8, D64; `CropBox.swift`, `CropDragOverlay.swift`, `CropGeometry.swift` | Decided (built) | a-crop-you-cannot-adjust-is-a-guess |

| D86 | **Full-screen capture is BUILT; what is missing is a Full Screen choice in the recording UI** — re-scoped 2026-09-09 from "add full-screen capture" | **The entry this replaces was wrong, and I wrote it the day before.** It said "`SCContentFilter(display:excludingWindows:)` makes the capture side small; the work is everything downstream of *which display*" and that "`StartOptions` needs a display selector with the same no-guessing stance" — all of which already existed. Verified end to end: `StartOptions.displayID` (`Protocol.swift:67`), `TargetReference.display(id:)` (`TargetReference.swift:47`), `SCContentFilter(display:excludingWindows:)` (`CaptureTarget.swift:82`), resolution with a `targetGone` error for a vanished display (`CachedTargetResolver.swift:180-195`), a CLI flag (`CommandLineParser.swift:277`), the host mapping it (`AutomationHost.swift:881-882`), **the no-guessing stance** — `MCPBridge` requires exactly one of `bundleIdentifier`/`displayID` (`MCPBridge.swift:228`) — and **the §5 half**, since `ConsentPolicy.evaluate` checks `displayID` BEFORE `bundleIdentifier` (`ConsentPolicy.swift:33`), so consent already treats a display grab as the widest capture. An agent has been able to record a whole display since D69. Only the human cannot ask for it. **This is the fifth time this project's planning surface has described built work as pending**, and the first one authored during the same session that then ranked it — which is why D91 exists | §4.11, §5, D42, D69, D91; `CaptureTarget.swift`, `ConsentPolicy.swift`, `StatusItemController.swift` | Decided (next; capture half already built) | i-planned-work-that-was-already-shipped |
| D82 | **The chapter panel is the PRECISE editing surface for a marker; the lane is the rough one** — a chapter's time is typed (`m:ss`, `h:mm:ss`, or bare seconds) in the same inline edit as its name, and both commit as one mutation | Product-owner direction, arriving with a bug that turned out to be the same subject. Dragging a marker on the lane is pixel work: on a 20-minute recording zoomed to fit, one pixel is seconds, and the person editing usually already KNOWS the number — "the demo starts at 1:30". So the panel takes typed times, and the lane keeps the drag. **The bug it arrived with**: a dragged marker snapped back to its old position until the timeline was clicked again. `EditorTimelineState.displayState` read `controller.markerTrackPoints`, a cache refreshed inside `applyAndSaveEvents`'s async `Task` on a `PreviewController` that is a plain class with no `@Published` — so the drag mutated `events` (published), SwiftUI re-rendered synchronously, read the *stale* cache, and the later refresh triggered no redraw at all. It now derives from `events` directly via `MarkerTrackPoints.compute`, the same function the cache calls. **One mutation, not `moveMarker` then `renameMarker`.** The first draft justified that with undo and was wrong — `UndoManager.groupsByEvent` is on by default, so two registrations in one run-loop pass collapse into a single ⌘Z, and the test written to prove otherwise passed against both implementations. The real reasons survived: two calls write `events.json` twice for one edit, and between them `events` publishes with the new time and the OLD name, a row nobody typed, rendered by every view watching the array. **Typed time is OUTPUT time**, converted through `Timebase` like every other coordinate the editor shows (M4b shipped that bug once). **Unreadable text keeps the current time rather than reading as zero** — a half-typed `1:` is somebody still typing, not a request to jump to the start — and `1:75` is refused rather than carried to 2:15, because the field closes on commit and a silent carry lands the chapter somewhere unseen. A time past the end clamps, matching a drag, which cannot go past the end because there is no timeline there to drop on | §4.5, D50, D56, D75, D79; `MarkerPane.swift`, `EditorWindowController.swift` (`applyChapterEdit`, `displayState`) | Decided (built) | the-panel-is-for-numbers-you-already-know |

| D83 | **QUEUED, not built: per-channel gain automation — a level line on each audio lane with draggable points and eased segments between them**, replacing the two global gain sliders | Product-owner direction, explicitly deferred ("record 4 as an enhancement, don't do it now"). The motivating case is the one Snitt is built for: a recording where system audio is loud under a demo and the narration is quiet, which a single global gain cannot fix — lowering system audio for the whole recording also lowers the part where it IS the content. **What makes it more than a UI**: `AVMutableAudioMix` already supports this natively via `setVolumeRamp(fromStartVolume:toEndVolume:timeRange:)`, so the export path needs ramps rather than a new mixing stage, and the current global gain is already an `AVMutableAudioMixInputParameters` volume. The work is the editing surface and the model — a per-channel envelope in SOURCE time that survives cuts, which is the part cuts make hard: a ramp spanning a removed span must be re-derived against `KeptRanges` or the eased curve lands wrong after every trim, exactly as marker positions do (D56). **Easing between points, not steps**, because a step change in gain is audible as a click. Not scheduled against a milestone; it re-scopes the editor's audio pane rather than joining an existing item | §4.8, D56, D57, D73; `EditorWindowController.swift` (audio gain), `CompositionBuilder.swift` (audio mix) | Queued (not built) | one-slider-cannot-fix-two-problems |

| D84 | **Editor keyboard shortcuts, driven by a REGISTRY that also renders the help** — space to start/stop, rewind, jump to previous/next marker, with every binding declared in one place that both installs the menu items and populates a **Help ▸ Keyboard Shortcuts** dialog | Product-owner direction, queued 2026-09-09 and promoted the same day once its real cost was measured. **The registry is the product owner's addition and it is the load-bearing part**: a shortcut list maintained separately from the bindings is a documentation surface that drifts from behaviour, which is precisely the class `ServerInstructionsTests` exists to catch — one source of truth is cheaper than a test that detects the divergence after it happens. **The entry that queued this over-priced it.** It warned that "space and the arrow keys are also text input" and that the shortcuts "belong on menu items with key equivalents, or behind a first-responder check" — that mechanism ALREADY SHIPS: `Cut Selection` binds a bare Backspace with `keyEquivalentModifierMask = []` (`AppShell.swift:141-145`), and `AppDelegate`'s `NSMenuItemValidation` conformance (`main.swift:529-534`) is what keeps that bare key from swallowing Backspace everywhere else in the app. So the work is additive: declare the bindings, add the menu items, widen one single-selector guard into a switch, and render the registry as a window. Jump-to-marker must navigate OUTPUT time so a marker inside a cut is skipped rather than seeked to, and needs a defined answer for "next" when the playhead sits exactly on one | §4.5, D50, D75, D82, D87; `AppShell.swift`, `main.swift` (`validateMenuItem`), `EditorWindowController.swift` | Decided (next) | one-source-of-truth-for-a-binding-and-its-documentation |

| D90 | **§13 retires the predicted total order.** Three sections replace it: *Shipped*, *Next — unblocked, in value order*, and *Blocked — and the edge that blocks each*, with dependencies written as explicit edges rather than as positions in a list | Unanimous across all five personas of the 2026-09-09 refinement debate, which is itself the evidence: no role defended the numbered order. The measured problem is that the order was **fiction maintained at a cost**. Of items 1-10, six were already BUILT — 1, 3, 4, 5, 6, and 2 "cleared" twice — so the list was roughly 60% historical ledger wearing a queue's numbering, and a reader had to work out which numbers were still live before trusting any of them. Meanwhile the last ~15 shipped things arrived as direct product-owner direction rather than off the list, and the list needed correcting four separate times for describing built work as pending. **What was load-bearing survives: the edges.** "Zoom + follow-mouse needs 6 and 7" is a fact about the code; "zoom is item 8" was a guess about a future nobody consulted. The Operator's framing carried it — a numbered list whose live entries cannot be distinguished from its dead ones is stale signage, and the decision log already holds the causal *why* that a total order was pretending to encode. Product/UX conceded outright, having opened by proposing a new position within the very order it then agreed to retire | §13, D47, D52, D65, D66, D91 | Decided (applied) | a-list-nobody-consults-is-a-cost-not-a-plan |

| D91 | **A queued or next item must NAME the symbol it would create, and a test asserts that symbol does not exist yet** | Five instances of one class: §13 recorded shipped work as pending for crop, D73's speaker-bleed warning, M5e's agent primitives (with three of S5's four premises stale), D57's transcript word spans, and D86 — the last written and then ranked inside a single session. `field-notes.md` (2026-09-08) concluded no cheap mechanical check could catch it, "because 'is this built?' is not answerable from prose." **That conclusion is what this decision overturns.** It is not answerable from prose — but a plan item does not have to be prose. An item that names the type it would add — the marker is a bare symbol name, checked as a DECLARATION (`struct X`, `func X`) rather than a mention, so the spec's own vocabulary appearing in a comment does not cry wolf — is making a claim a grep falsifies in milliseconds, and every one of the five instances would have failed such a check on the day it was written. **Known limit, stated rather than hidden**: it covers only items whose completion introduces a named symbol. "A Full Screen menu item" and "pick a licence" carry no marker, so the habit of reading an item's premises against the code remains the primary defence and this is the backstop. The precedent is already here: `ServerInstructionsTests` guards prose that drifted from the agent surface, and `NotarizeScriptTests` reads a shell script. **Five hits is past the point where patching instances is defensible** — the recurrence rule says the third demands a structural guard or an explicit decision not to fix, and this is the fifth. Deliberately weak by design: it proves absence, never presence, so it cannot tell you an item IS built — only that a "not yet built" claim has already stopped being true | §13, §15, D47, D90; `Tests/SnittDocumentTests/` | Decided (applied) | prose-cannot-be-checked-but-a-symbol-name-can |

| D92 | **MPL-2.0, with a CLA** — file-level copyleft, plus contributor terms that keep relicensing possible | Product-owner decision, 2026-09-09, answering "open source, but I don't want commercial competitors taking the code and charging for it". **The tension named first, because it is real**: OSI open source REQUIRES permitting commercial use and sale, so no open-source licence delivers "nobody may charge for it" — that needs a source-available licence (FSL, PolyForm), which forfeits the word. GPL-3.0 was recommended as the strongest deterrent that stays open source: a competitor may sell it but must publish their whole derivative's source, which kills the proprietary fork. **MPL was chosen over it deliberately, and the reason is Mac App Store distribution** — Apple's terms impose restrictions GPL forbids (the VLC case), and §13's M8 keeps that half alive on §4.3's own terms. AGPL was rejected as dead weight: its teeth are the network clause, and D62 puts transcription ON DEVICE precisely so there is no service for it to bite. **The CLA is what makes this reversible, and that is the point of the pair.** MPL is the weakest of the four against the stated worry — a competitor may wrap Snitt in a closed product and publish only their edits to Snitt's own files — so the licence is the option-preserving choice and the CLA is the escape hatch: contributors licence their work broadly enough that the project can relicense later, which is impossible once contributions arrive under terms needing unanimous permission to change. Not a copyright assignment; contributors keep their copyright. **Default MPL, no Exhibit B**, so the code stays GPL-compatible — other open projects using it was never the threat. **The file-level boundary is a mechanical property and therefore guarded**: MPL obligations attach to "Covered Software" and Exhibit A is how a file declares itself covered, so a new file without the notice silently leaves the licence's protection. `LicenseHeaderTests` fails the build on a missing notice, and on a `LICENSE` that does not match what the notices point at. **The strongest anti-clone tool is not the licence at all** — a fork can copy the code but cannot call itself Snitt | §13, D54, D66; `LICENSE`, `CLA.md`, `CONTRIBUTING.md`, `LicenseHeaderTests.swift` | Decided (applied) | no-open-licence-can-stop-a-competitor-so-keep-the-right-to-change-it |
| D93 | **SUPERSEDED by D102 (2026-09-15) — narration recorded in the editor, anchored to the FOOTAGE.** The anchoring survives; the third track does not | ORIGINALLY: | Product-owner direction 2026-09-12, ranked 2026-09-14 ("do D93 next"). **The decision that needed making was time.** A voiceover is spoken against OUTPUT time while every other track lives in SOURCE time, and the spec recorded this as "the first case in `Timebase` with no obvious right answer". Ruled: narration is anchored to the footage. Each stretch is resolved ONCE, at record time, into SOURCE spans through the EDL then in force (`VoiceoverPlacement.segments`), so a later cut takes the narration over the removed picture with it and leaves the rest aligned with the frames it describes. **The rejected alternative** — anchoring to the finished timeline — keeps the audio continuous and lets the picture slide underneath, so narration that described one thing silently ends up over another, with no symptom until somebody watches the whole thing. **The cost, stated rather than hidden**: narration spoken ACROSS an existing cut comes apart if that cut is later undone, because each half stays with its own footage — pinned by `restoringFootageSeparatesSplitNarration`, a test written expecting the opposite. **Nothing is destroyed**: the audio is one file in the bundle, never trimmed, and `segments` is never rewritten, so undo restores narration with the picture — §4.5's non-destructive rule applying to narration for free. `AudioTrackOrder` splits into `captured` (what the recorder writes) and `canonical` (what the composition's audio tracks are named), with "voiceover" appended third — safe because `AssetWriterSink` adds both audio inputs unconditionally, verified against a real recording rather than inferred. `PassthroughEligibility` gains a `.voiceover` disqualifier: passthrough copies already-encoded samples and narration has none, so an eligible export would ship the picture, the original audio, and no narration at all | §4.5, §7, D64, D83, D91; `VoiceoverTrack`, `VoiceoverPlacement`, `VoiceoverRecorder`, `AudioTrackOrder`, `PassthroughEligibility` | Built (2026-09-14) | narration-is-a-new-track-in-output-time-not-a-second-mic |
| D94 | **An on-device generated title for a recording** — queued, deferred after measurement | Panel proposal (2026-09-12 refinement), built as far as a probe and then stopped on the numbers. `FoundationModels` is genuinely available — `SystemLanguageModel.default.availability` reports `.available`, 23 languages, on macOS 26.5.2 — and a `@Generable` title over a real transcript took 6.65s alone, 10.83s with git context, returning "SoundCloud Song Search" against a bare "SoundCloud" depending on how much context it was given. **Deferred because the floor is already earned without it**: D77's macOS 26 requirement is paid for by the `SpeechAnalyzer` port, which deleted 132 lines and found six more words, so this no longer has to justify the platform floor and can be judged on its own merits. On those merits it is not ready. A confidently wrong title is WORSE than the timestamp it replaces, because a timestamp is not trusted and a name is — so it needs a transcript-length floor or a confidence gate first. It is also the first non-reproducible artifact in a format whose §7 pitch is that everything re-derives from immutable inputs, so the result has to be stored in `meta.json` rather than recomputed, and ~10s cannot sit on the stop path. Recorded rather than dropped: the capability is real and the measurements are the expensive part of deciding | §5, §7, §4.6, D62, D77, D91; `FoundationModels`, `RecordingMetadata`, `BundleNaming` | Queued (deferred) | a-confidently-wrong-name-is-worse-than-a-timestamp |
| D95 | **An opt-in allowing agent recording with nobody at the keyboard, as an EXPIRING grant** | Product-owner request, 2026-09-13, for remote-control sessions where an agent works an unattended machine and the recording is how anyone sees what it did. Reading the agent path found exactly ONE thing on it needing a person: Screen Recording is requested lazily, at first record, and macOS re-confirms it periodically for anything on the bypass path (§5.2, §5.5). So the mechanism is confirmation, not a new permission — turning the setting on is the one moment a person is guaranteed to be present, and `UnattendedRecordingToggle` spends it running §4.10's `PermissionLadder` against `.screenRecording`. **§5.4's staleness objection is what shaped it**: a standing grant "cannot know what the target is showing six weeks later", so this one EXPIRES after `UnattendedRecordingGrant.renewalDays` and renewing means switching it off and on again in front of the machine. Thirty days matches the OS re-consent cadence it tracks, so the two renewals coincide; the number is interpolated into the help text from the constant, with a mutation line pinning that. §5.4's spoofing objection is separately answerable now that the socket reads the caller's signing identity. The grant is subordinate to §5.3's global opt-in and COMPOSED from it rather than stored, so the two cannot disagree | §5.1, §5.3, §5.4, §5.5, D42, D91; `UnattendedRecordingGrant`, `UnattendedRecordingToggle`, `PermissionLadder`, `PeerIdentity` | Decided and built 2026-09-13 | the-picker-is-policy-not-capability |
| D96 | **Estimate a GIF's size by encoding ~10 sampled frames and extrapolating** — queued, not designed | Product-owner request, 2026-09-13. `ExportEstimator` refuses GIF today and says why — GIF size tracks how much the picture MOVES rather than how long it runs — so the sheet shows no estimate for the one format whose size is hardest to guess. Sampling is the same move `exportSlice` already makes for mp4 ("so a size can be MEASURED rather than modelled"), and spreading the samples captures average motion instead of one quiet second. **The obvious objection does not apply, and that was checked**: scattered frames would normally compress worse than consecutive ones and bias the estimate high, but `EstimateError`'s own text records that these frames "carry no interframe compression", so per-frame cost is roughly independent of neighbours. **The objection that does apply** is the global colour map — ImageIO fits ONE palette across every frame, the same fact behind the 2026-09-13 GIF crash, so a palette fitted to ten frames suits each better than one covering three hundred and the sample will likely under-report. That is a calibration factor to MEASURE against real exports, not to reason out: the direction is predictable, the magnitude is not. The sample must also be encoded at the post-`GIFExporter.maximumWidth` scale, or it describes a different file, and must stay bounded — GIF encoding is what crashed the app | §8, D91; `ExportEstimator`, `GIFExporter`, `ExportPreflight` | Queued (not designed) | measure-a-sample-then-calibrate-the-palette-effect |
| D97 | **QUEUED, not built: one title row, and an Xcode-style side panel** — the editor's toolbar becomes a real `NSToolbar` and the rail an inspector-style split item | Product-owner direction 2026-09-14, with Finder and Xcode screenshots as the reference. **The shape is already right**: the window is `.fullSizeContentView` with a hidden title, so the toolbar row IS the titlebar, and `EditorToolbar` already puts title-over-subtitle at the leading edge and the panel toggle at the trailing one. What it is not is an `NSToolbar`, and that is the whole cost — a hand-built `HStack` gets no traffic-light inset (so the first 78pt are dead space the window's own buttons sit in), no overflow chevron (a narrow window clips controls instead), none of the material, separator or scroll-edge effect the system draws under a real titlebar, and no trailing accessory position, which is exactly where Xcode's inspector toggle lives. **The panel half** wants `NSSplitViewController` with an inspector item: its own background material and hard separator are what make Xcode's inspector read as a compartment rather than as content, and it brings the divider behaviour and collapse animation `ResizableDivider` currently reimplements. **Not small**: the toolbar is SwiftUI inside an `NSHostingView` and `NSToolbar` is AppKit, so this reworks how the editor window is ASSEMBLED rather than how it is painted | §4.14, D45, D58, D59, D91; `EditorChrome.swift`, `EditorWindowController.makeWindow`, `ResizableDivider.swift` | Queued (not built) | the-titlebar-is-a-toolbar-or-it-is-a-strip-of-buttons |
| D98 | **Replace the CLA with a DCO plus an Apache-2.0 additional grant** | Product-owner request 2026-09-14, ranked after the voiceover work. **Both of the CLA's stated reasons are dead.** `CONTRIBUTING.md` justifies it as enabling a future relicence for "a Mac App Store build, or a commercial licence beside the free one" — D66 killed the second ("there is no licence to enforce and no subscription to gate"), and the first is not true: MPL-2.0 already ships on the App Store (Brave on iOS, Collabora Online on iOS/iPadOS/macOS), because Apple's terms conflict with the GPL's whole-work conditions rather than the MPL's file-scoped ones. Snitt's real App Store blockers are `CGEventTap` and the agent surface, neither of which is a licensing problem. **A DCO alone cannot replace it** — a DCO sets inbound equal to outbound and grants nothing extra, so a DCO-only project needs unanimous permission to relicense. The working form is the DCO's own wording, which certifies the right to submit "under the open source license indicated in the file": declare that as a DUAL grant, per Rust's formula. **It is not exclusive** — everyone gets the same permissive rights, not only the maintainer, and a CLA remains the only instrument that makes a closed fork the maintainer's alone. Binds future contributions only; no third party had ever signed, so nothing needed reconciling | §4.3, D66, D91, D97; `CONTRIBUTING.md`, `README.md`, `CLA.md`, `.github/pull_request_template.md` | Built | a-dco-grants-nothing-extra-so-the-grant-has-to-be-declared |
| D99 | **QUEUED, not built: select, move and scale the marker and subtitle overlays in the editor** — global placement first, per-item later | Product-owner direction 2026-09-14. **Most of the machinery is already right**: `OverlayLayout` is the single source the preview, the mp4 burn and the GIF burn all read their geometry from (D51), so one global offset and scale reach all three — which is what makes this a feature rather than a rewrite. **The decision is units, not dragging**: the offset must be stored in UNIT terms because `OverlayLayout` sizes everything from `picture.height`, and a position in points would put an overlay dragged over a 4K preview somewhere else in a 720p export — the exact class that type exists to prevent. The EDL gains an additive field, no schema bump, per `crop`'s pattern. **The harder half is the gesture**: the preview overlay returns nil from `hitTest` on purpose so it never takes a click meant for the player, so selection has to be live only while something is selected, the way `CropDragOverlay` already is. **Per-item placement is a different shape** and is deferred: a per-marker offset belongs on the marker, which lives in `events.json`, so it lands on the event model, undo, and the marker editor — none of which the global version touches | §9, D51, D64, D91; `OverlayLayout`, `OverlayTextView`, `TextOverlayComposition`, `TextOverlayFrame`, `CropDragOverlay` | Queued (not built) | one-layout-type-means-one-offset-reaches-every-renderer |
| D100 | **Narration you WRITE, from a `+` in the transcript header** | Product-owner request 2026-09-14. Stand at a moment, press `+`, type what should be said; `AuthoredNarration.words` splits it at `SpeechRate.wordsPerSecond` onto the voiceover track, and the rows, captions and phrase chips treat it exactly as narration the recogniser heard. **It pays before D101 exists**: a written screencast still gets subtitles, a transcript to edit and a narration lane, and rewriting a sentence beats re-recording a take. **`isAuthored` is load-bearing** — `deleteWords` removes a word by CUTTING THE FOOTAGE under it, which is right for speech and nonsense for a line with no seconds behind it, so authored words are removed from the transcript instead and a mixed selection does each to its own. Anchored in SOURCE time so a cut above does not drag it; timed at the reading speed, an assumption D101 replaces with real durations. **Undo of the FIRST line removes the transcript rather than emptying it**: empty reads as "the recogniser heard nothing". Deleting is a keystroke, not a button, and the shift-range runs along DISPLAY order because rows are grouped by voice | D62, D93, D101; `AuthoredNarration`, `SpeechRate`, `TranscriptSelection`, `TranscriptPane` | Built | a-written-line-has-no-footage-so-deleting-it-cannot-cut |
| D101 | **QUEUED, not built: speak the written narration** | Requested 2026-09-02 and recorded 2026-09-14 — it had been asked for and never written down, which is the failure D91 exists to prevent. **The input already exists**: D100's authored phrases ARE the script, so this decision is about synthesis alone. `AVSpeechSynthesizer.write(_:toBufferCallback:)` renders to buffers rather than speakers, which is what an offline render needs. **Timings become real** — D100 times a line at the reading speed for want of anything better, and a synthesiser returns the durations it produced, so words should be re-timed from the render; that is the one part which is not purely additive. It writes the third audio track `AudioTrackOrder.canonical` already reserves and `VoiceoverTrack` already places, so the composition side is done. Undecided: whether a synthesised take replaces a recorded one on the same track, and what happens to a written line an edit has left behind. §5 makes it a generated artifact, so the audit record must say a model produced the audio | D100, D93, D94, §5; `AudioTrackOrder`, `VoiceoverTrack` | Queued (not built) | the-script-is-already-there-so-this-is-only-synthesis |
| D102 | **A recorded take OVER-DUBS the microphone; the third track is reserved for synthesis** | Product-owner request 2026-09-15 after using the app, amending D93: "it's overly complicated to have a third audio track for voiceover". A third lane carries one kind of thing, has a mute and a gain nobody wants to set separately, and puts three audio sources in the model of a recording that has two. **§4.5 is untouched and that is what makes it possible** — `capture.mov` is still never written, a take is its own file, and the exporter ASSEMBLES the microphone from both, so deleting a take restores the original because the original was never overwritten. `MicrophoneTimeline` is the piece D93 never needed: it returns pieces that TILE the kept footage, no gaps and no overlaps. **Several takes**, later wins where they overlap — fixing two sentences must not mean re-recording everything between them. **Old documents DISCARD their narration** (product-owner's choice): a migration would have to decide on the author's behalf that narration recorded to sit BESIDE the microphone should now silence it. The audio file stays in the bundle; the lane goes with the narration. **Lossy in the transcript in a way D93 was not** — a take replaces, so the capture's words under it are removed rather than kept beside them | D93, D101, §4.5; `Overdub`, `MicrophoneTimeline`, `MicrophoneWaveform`, `CompositionBuilder` | Built | a-take-replaces-the-microphone-so-nothing-plays-beside-it |

`conformance: 2026-09-07` (post-D66 refinement pass)

`conformance: 2026-09-09` — walk of D74-D89 against the tree. One drift found
and fixed: §13 item 3 claimed D57's use of transcript word spans was "not yet
built" while `AutoDeepTrim.deadSpans` takes a `transcript:` and both call sites
pass one. Fourth instance of this list recording shipped work as pending. Also
added: the 2026-09-09 editor-defect batch to item 2, D80 and the CI work to
Shipped, and a "Queued enhancements" subsection for D83/D84/D86/D89, which had
decision-log entries and no presence on the planning surface at all.

### Termination

**Condition 1 — converged.** The single contested item settled in one
cross-examination round (budget allowed two); the remaining seven Important items
were uncontested and recorded directly; the conformance walk is clean.

**Verdict: Proceed.** Next step is `superpowers:writing-plans` against §13.

Not covered by this pass, by design: adversarial review of code (none exists
yet — that belongs to `/code-review` once the plan produces a diff), and a
zero-trust plan-vs-implementation audit. This was the light, memory-carrying pass.

---

## Refinement pass — 2026-09-09 (§13 priority)

Question asked: what is built next, and where do the four queued enhancements sit
against items 7-10 and against "pick a licence". Five persona sub-agents diverged
in parallel; all five were resumed with their own context for one cross-examination
round on the two contested items. **Verdict: Proceed** — the spec's content was
sound; its §13 *structure* was not.

**What the grounding found.** Items 7, 9 and 10 had accurate premises. Two did not:
D86 was already built end to end on the agent path, and D84's cost was overstated
by its own entry because the bare-key-plus-validation mechanism it needs already
ships. Both errors were mine, written the previous day — a thin source caught
twice, which is why D91 exists rather than a sixth correction.

**What the debate settled.** D84 next, through a shortcut registry that also feeds
a Help ▸ Keyboard Shortcuts dialog (product-owner addition: one source of truth
beats a list that drifts). D86 re-scoped to its missing GUI affordance. The licence
promoted, because shipped copies cannot auto-update while the repo is private.
§13's numbered order retired unanimously (D90) — six of ten entries were already
BUILT, so the numbering was stale signage over a historical ledger.

**Two claims this pass RETIRED rather than ranked.** M5d's defect #6 cannot fire
today: the watchdog path already handles it and stream-death has no handler to
reach it from, so it is a defect in an unbuilt plan and must not be cited as a live
bug. And item 7 was under-priced: mis-stamped pre-fix bundles exist on disk, and it
is exactly the non-additive change `EditDecisionList` warns turns that into silent
unrecoverable loss — it now carries a migration-test prerequisite.

**Not covered by this pass, by design:** adversarial review of code (that is
`/code-review` against a diff), and a zero-trust plan-vs-implementation audit. This
was the light, memory-carrying pass. Accessibility is discussed in the spec but no
explicit annotations exist in `Sources/`; SwiftUI defaults cover standard controls
and the custom-drawn timeline is the open question. Not assessed. The decision log
is past the ~50-entry compaction threshold and was deliberately not compacted.

`conformance: 2026-09-09` (post-§13-restructure refinement pass)
