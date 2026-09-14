# Privacy and permissions

## What leaves your Mac

Nothing, except an update check.

There is no account, no upload, no telemetry, and no analytics. Transcription
runs on-device. The only network request Snitt makes is Sparkle asking whether
a newer version exists, and that is off until you turn it on.

## What macOS will ask for

Snitt asks for each permission at the moment it first needs it, never at launch,
and always after telling you why.

| Permission | When | What it is for |
|---|---|---|
| **Screen Recording** | First recording | Capturing the screen, and its audio. macOS covers both under this one permission. |
| **Microphone** | First recording with "Record microphone" on | Your voice, on its own track. Never used otherwise. |
| **Input Monitoring** | First recording with "Capture events" on | **When** you click and type, never which keys. |

### macOS will ask again, about monthly

That is the platform, not a bug, and Snitt explains it the first time it
happens. Approving it keeps recording working. A prompt appearing **more often
than monthly** is a real problem worth reporting.

## Input logging records timing, not characters

"Capture events" records that a keystroke happened and when. It does not record
which key, and there is no code path that can.

Even so, timing alone narrows a guess at what was typed, which is why the log
never leaves the bundle and is off by default. It covers activity **anywhere on
this Mac while recording**, not only the window being captured, because the tap
is session-wide while the video is window-scoped.

## Agent recording

An agent can drive Snitt through the [CLI or MCP server](Agents-the-CLI-and-MCP),
and that is a materially different privacy surface from a person pressing a
hotkey. So it carries extra rules:

- **Off by default**, behind an explicit opt-in in **Settings ▸ Agent**
- **A visible indicator for the whole session**, with a menu-bar kill switch
- **A maximum session duration**, so an abandoned agent cannot fill the disk
- **No silent escalation to full-display.** An agent may record a window;
  recording a whole display needs its own grant

### Unattended recording

**Settings ▸ Agent ▸ Allow unattended** lets an agent record a machine nobody is
sitting at, for remote sessions where the recording is how anyone sees what
happened.

Turning it on confirms Screen Recording **then**, while you are present, because
that is the one moment it can be confirmed. The grant then **expires after 30
days** and must be renewed deliberately. That is not bureaucracy: a standing
permission cannot know what your screen shows six weeks later, and unattended is
precisely when nobody is watching. Thirty days matches how often macOS re-checks
the underlying permission, so the two renewals coincide.

## Diagnostics

`snitt diagnostics export` writes a JSON file for support: recent log lines,
permission states, and session metadata with window titles and file paths
stripped.

Crash reports are included only if you turn that on in **Settings ▸ Updates &
Diagnostics**. Nothing is sent anywhere. The bundle is a file you choose to
share, so read it before you do.
