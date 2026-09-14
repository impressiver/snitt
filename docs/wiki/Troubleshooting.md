# Troubleshooting

The failures below all look like bugs and are not. If yours is not here,
[open an issue](https://github.com/impressiver/snitt/issues/new/choose) — the
form asks for your macOS version, Snitt version and how you installed it,
because those three answer most of it.

## Recording

**"Snitt needs permission to record the screen", even though I granted it.**
macOS ties Screen Recording to an app's **code signature**, and the grant does
not survive the signature changing. That happens when you rebuild from source,
or replace the app with a build signed by a different identity. Remove Snitt
from **System Settings ▸ Privacy & Security ▸ Screen Recording** with the "−"
button, add it back, then **quit and relaunch** — the grant takes effect on the
next launch, not immediately.

**macOS keeps asking about screen recording.** Roughly monthly is the platform
working as intended, and Snitt explains it the first time. More often than that
is a real problem, usually an unstable code-signing identity. Worth reporting.

**The hotkey does nothing.** Something else owns that combination — macOS's own
screenshot shortcuts are the usual culprit. Pick another in **Settings ▸
Keyboard Shortcuts**; the recorder tells you if the one you press is taken.

**Nothing was recorded and there is no error.** Check the menu-bar indicator. If
it never showed a recording state, the recording never started, and the reason
is almost always a permission that was refused rather than granted.

## Transcript

**The transcript is empty.** Transcription reads the **microphone track only**.
A screen recording of a video call, where every voice arrived as system audio,
correctly transcribes to nothing. Turn on **Settings ▸ What gets recorded ▸
Record microphone** before recording if you want your narration transcribed.

**It got a name wrong.** Expected: a general speech model has never heard your
symbol names. Open the transcript pane's **Refine** panel, list the words to
expect, and run it again. Or double-click any word and correct it directly.

## Auto-trim

**Auto-Trim found nothing to cut.** It needs **Capture events** to have been on
*during the recording*. Without that log there is no way to tell someone
thinking from an empty room, and it will not guess.

## Export

**The GIF is enormous.** GIF size tracks how much the picture **moves**, not how
long it runs. A scrolling page is far more expensive than a static screen. Trim
harder, or export mp4 — every destination worth sending to accepts it.

**The export has no subtitles or markers.** Those are opt-in per export. Turn
them on in the export sheet's Overlays section, or in **Playback ▸ Show** before
you open it, which seeds the sheet.

## Updates

**"Check for updates" finds nothing.** It is off until you turn it on, in
**Settings ▸ Updates & Diagnostics**.

## Agents

**An agent says recording is not permitted.** **Settings ▸ Agent ▸ Allow
recording** is off. It is off by default on purpose.

**It worked, then stopped while I was away.** If you were relying on
**Allow unattended**, check whether the grant lapsed — it expires after 30 days
and the Settings row says when. macOS may also have withdrawn Screen Recording
on its own schedule, which needs a person at the machine and is the one limit
no setting removes.

## Getting help

`snitt diagnostics export` writes a JSON file with recent logs, permission
states and redacted session metadata. Window titles and file paths are stripped,
but **read it before attaching it** to anything public.
