# Snitt

**A native macOS screen recorder that a coding agent can drive.**

Record a window, trim it, export it — in under a minute, from the menu bar or
from a script. Transcription runs on your Mac and the recording never leaves it.

*Snitt* is Swedish and Norwegian for **cut** — as in a film edit, or a
cross-section.

> **Status: early.** v0.1.0 is signed, notarized and shipping, and it is used
> daily by the person who writes it. Interfaces still move. If you find a defect
> the honest place to look for what is already known is
> [`docs/superpowers/notes/field-notes.md`](docs/superpowers/notes/field-notes.md).

---

## Why this exists

macOS already has `Cmd+Shift+5`, which is free and pre-installed. Snitt has to
earn its place against that, and it does so through a **combination** rather
than any single feature:

- **An agent can drive it.** Claude Code or Codex can record a demo of a feature
  it just built and attach it to a pull request — over MCP or a CLI, with the
  same core the GUI uses.
- **Transcription is on-device.** Speech never goes to a hosted service. Words
  carry timings, so you can click a word to seek, or select a phrase and delete
  it to cut those seconds.
- **Editing is focused, not a timeline suite.** Cuts, folds, crop, markers,
  chapters, per-track audio — the things you need before sharing, and not much
  more.
- **It is open source**, under the MPL, with no subscription.

Any one of those exists elsewhere. Together they do not.

## Requirements

- **macOS 26 (Tahoe)** or later
- Screen Recording permission — **granted once**, not monthly. macOS re-prompts
  apps that enumerate screen content themselves; Snitt goes through the system
  picker instead, which is what keeps that grant a one-time event.
- Microphone and Speech permissions only if you use them

## Install

Download the latest signed build from
[Releases](https://github.com/impressiver/snitt/releases), or build from source:

```bash
git clone https://github.com/impressiver/snitt.git
cd snitt
./Scripts/make-app.sh          # builds build/Snitt.app
open build/Snitt.app
```

Updates arrive in-app through Sparkle.

## Recording

**From the menu bar.** Click the status item, or press the global hotkey. The
system picker appears so you choose exactly what is captured — every time, by
design. No window opens while you record; the editor appears when you stop.

**From an agent.** Register the MCP server once:

```bash
snitt setup --apply
```

Then an agent can call `snitt_start_recording`, `snitt_add_marker`,
`snitt_stop_recording`, `snitt_export` and a dozen more. Markers an agent drops
as it works become chapters in the exported video.

**From a shell.**

```bash
snitt targets list                                  # what can be recorded
snitt record start --app com.google.Chrome          # prints a session id
snitt record mark <session> --label "the bug"
snitt record stop <session>                         # prints the bundle path

snitt auto-deep-trim recording.snitt                # cut the dead air
snitt export recording.snitt --format mp4 --out demo.mp4 \
      --resolution 1080p --chapters
```

`snitt --help` lists every verb. Output is JSON on stdout and human text on
stderr, so a script can parse one while a person reads the other.

## The `.snitt` document

A recording is a bundle, not a file. Inside it: the untouched capture, an edit
list, an event log, a transcript, and metadata. **Edits never touch the
capture** — trimming and cropping write to `edit.json`, so every edit is
reversible and the original is always there. Export renders the result.

Because the edit list is plain JSON beside the video, a script or an agent can
read and change an edit without going near the GUI.

## Privacy

- **Transcription is on-device.** Audio is never uploaded.
- **Input logging records *that* you typed, never *what***, and is off by default.
- **The picker appears on every recording**, so nothing is ever captured that you
  did not just select.
- **No analytics, no telemetry.** The only network call Snitt makes is Sparkle
  checking for updates.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md), and
[`docs/DEVELOPING.md`](docs/DEVELOPING.md) for environment setup and the traps
worth knowing before your first build.

Two things to know up front: every source file carries an MPL notice (a test
enforces it), and every test must name a plausible wrong implementation and be
verified to fail against it.

Contributions require agreeing to the [CLA](CLA.md). It is short, and it is not a
copyright assignment — you keep your copyright.

## Design

Snitt is built from a written spec with a numbered decision log — every
non-obvious call, why it was made, and what evidence it rests on:
[`docs/superpowers/specs/2026-09-02-snitt-design.md`](docs/superpowers/specs/2026-09-02-snitt-design.md).

If you want to know why something works the way it does, that file almost
certainly says.

## Licence

[Mozilla Public License 2.0](LICENSE). File-level copyleft: changes to Snitt's
own files stay open, while a larger work that uses Snitt may carry its own
terms.
