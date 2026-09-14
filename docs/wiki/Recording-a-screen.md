# Recording a screen

## Starting and stopping

**The global hotkey** (⌥⌘5 by default) starts and stops recording. **The
menu-bar item** does the same. Both are the fast path, and neither opens a
window: you press the key, choose what to capture, and the app gets out of the
way. The editor appears when you stop.

You can change both hotkeys in **Settings ▸ Keyboard Shortcuts**.

## The picker appears every time

When you start a recording, macOS's own window picker appears and you choose
what is captured. Every recording, with no way to turn it off.

That is deliberate, and there are two reasons:

1. **Choosing the target is the moment you decide what to share.** Reusing your
   last choice silently is exactly when you record the window you forgot was
   behind the one you meant.
2. **It is the system picker, not one Snitt drew.** An app that enumerates
   windows itself gets charged a recurring re-consent prompt by macOS, roughly
   monthly. Going through the system picker avoids that, so you grant Screen
   Recording once instead of being asked again and again.

## While it is recording

The menu-bar item shows the recording state for the whole session, and clicking
it stops the recording. That indicator is not decoration: nothing records
without it showing.

**Markers.** Press the marker hotkey (⌥⌘M by default) at any point to drop a
marker. Markers become chapters in an exported video and rows in the editor's
panel, and they are the fastest way to find the moment that mattered in a long
recording. Add a label later.

**Pause and resume** from the menu-bar item. A paused recording keeps one
continuous document rather than producing several files to stitch together.

## What gets captured alongside the video

Both of these are off until you turn them on, in **Settings ▸ What gets
recorded**:

- **Record microphone** captures your voice on a separate track from system
  audio, so the two can be balanced or muted independently later. Snitt warns
  you if your speakers are likely to bleed into the microphone.
- **Capture events** records **when** you clicked and typed, never what you
  typed. That timing is what lets the editor find dead air and trim it, and what
  lets the editor draw click rings. The log stays inside the recording's bundle.

## Opening a video you already have

Snitt edits footage it did not record. **File ▸ Open** takes an `.mp4` or
`.mov` as readily as a `.snitt`, **File ▸ New from Clipboard** (⌘N) opens
whatever video you last copied, and you can drop a video on Snitt's Dock icon
or open it with Snitt from the Finder.

The file is **copied** into a new recording, so the original is left exactly
where it is and nothing is re-encoded. After that there is no difference
between it and something Snitt recorded: auto-trim, cutting, markers,
transcription and voiceover all work the same, because they all work on the
recording inside the document.

An opened video lives in a temporary folder until you save it. **⌘S** asks
where it belongs, once. After that it saves continuously like any other
recording, and ⌘S has nothing left to do.

*Dropping a video onto an editor that already has one does nothing yet.* A
`.snitt` holds a single recording, and every marker, cut and caption is a
position in it — splicing a second video in needs the document to hold a
sequence of clips instead, which is a change to the format rather than a
setting.

## Where recordings go

`~/Documents/Snitt` by default, changeable in **Settings ▸ Recordings folder**.

Each recording is a `.snitt` bundle rather than a plain video file. See
[The .snitt document](The-snitt-document) for what is inside one and why it is
shaped that way.
