# M1 — manual verification record

**Date:** 2026-09-02 · **macOS:** 26.5.2 · **Status:** Passed, with caveats

Definition-of-Done item 4 from the M0–M1 plan: *"A manual recording produces a
bundle whose `capture.mov` has 1 video and 2 audio tracks."*

## Result — PASSED

A 5-second recording via `Snitt.app` produced
`~/Desktop/SnittProbe-1788386057.snitt` containing all four bundle members
(`capture.mov` 5.5 MB, `meta.json`, `events.json`, `edit.json`).

Track inspection via AVFoundation (`mdls` returns null — Spotlight does not
index a `.mov` nested inside a package directory, so the plan's suggested
`mdls` check is not usable and AVFoundation is the authoritative substitute):

```
video tracks : 1
audio tracks : 2
duration     : 7.95s
  audio[0]  : 7.88s, 1 channel(s)
  audio[1]  : 7.93s, 1 channel(s)
  video[0]  : 2056x1328 @ 56.7fps
```

## What this confirms

- **The three-track pipeline works end to end against real ScreenCaptureKit**,
  not just synthetic buffers. One video track, two discrete audio tracks.
- **Both audio tracks carry content** (7.88s and 7.93s), so microphone AND
  system audio both captured — the single-`SCStream` design of §9 works as
  specified, and macOS 15's native mic delivery is confirmed in practice.
- **The `channelCount = 1` fix is correct.** Both audio tracks are 1-channel.
  The stereo-into-mono-AAC conversion failure that fix pre-empted did not occur.
- **The duration fix is correct.** `meta.json` reports 8.13s against a 7.95s
  movie — agreement within 0.2s. Before the fix, finalization time would have
  inflated the metadata further.
- **The frame-status guard did not over-filter.** Video recorded continuously at
  ~57 fps; the `.complete`-only guard did not drop real frames.

## Caveats — read before treating this as full validation

1. **The grant was Terminal's, not Snitt.app's.** The successful run executed
   the binary directly from a terminal, so the TCC responsible process was
   Terminal, which already held Screen Recording. Launching `Snitt.app`
   independently via `open` initially crashed for lack of its own grant. The
   §4.9 responsible-process story for the real signed app is therefore still
   unverified, exactly as S3's caveat notes. Verify at M5 when Developer ID
   signing lands and the identity stops changing per build.

2. **Recorded at point resolution, not pixel resolution.** 2056x1328 on a
   Retina display is roughly half native. This is finding O-4 from the
   whole-branch review, now empirically confirmed rather than merely predicted.
   It is an undocumented quality decision inherited from using
   `SCDisplay.width/height` (points) as the capture dimensions. Decide
   deliberately at M2 whether to capture at backing-scale resolution.

3. **Requested 5 seconds, recorded ~8.** `recorder.start()` appears to take
   ~3 seconds before returning, and `startedAt` is stamped before
   `session.start()` completes (the deferred Task 10 finding 1c). The metadata
   is self-consistent, so nothing is wrong with the bundle — but a caller asking
   for a 5-second clip gets 8. Move the `startedAt` stamp after `start()`
   returns when M2 wires up real recording controls.

## Probe defect found and fixed during this check

`snitt-probe` originally died with a bare `EXC_BREAKPOINT` / SIGTRAP when
Screen Recording was denied — an uncaught error in top-level Swift code, with
no message. That is precisely the deferred Task 10 minor ("snitt-probe does not
contextualize errors ... an uncaught trap is unhelpful for the TCC debugging it
exists to do"), and it cost one wasted run before being fixed. The probe now
preflights and requests Screen Recording explicitly, and reports actionable
errors with hints at every failure point.

The lesson matches S1's: a diagnostic tool that cannot report its own failure
is not a diagnostic tool.
