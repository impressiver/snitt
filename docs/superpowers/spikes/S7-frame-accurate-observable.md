# S7 — An observable for frame-accurate seeking

**Question (M4b):** M4a established that `AVPlayer.currentTime()` reports the
seek *target*, not the decoded frame — so nothing could prove a seek actually
landed where it claimed. M4b's headline feature is frame-accurate scrubbing.
Is `AVPlayerItemVideoOutput.copyPixelBuffer(forItemTime:)` a usable observable,
and does it work on a paused item?

**Date:** 2026-09-04 · **macOS:** 26.5.2 · **Status:** Resolved

## Method

A throwaway test inside `SnittAppTests`, driving the real
`CompositionBuilder.build` output through an `AVPlayerItem` with an
`AVPlayerItemVideoOutput` attached, seeking to three times with zero
tolerance and fingerprinting each returned buffer by mean sample value.

## The first run was wrong, and the reason matters

Run 1 reported **identical fingerprints (160.17) at all three seeks** and the
verdict "NOT usable — frames indistinguishable".

That was a defect in the instrument, not a finding. `writeSyntheticMovie`
fills every frame with `memset(base, 128, …)` — **every frame of the fixture
is the same flat gray**. Asking it to distinguish frames could only ever
return "indistinguishable", regardless of what the API does.

This repo already records the identical mistake in S1's revision history:
*"an all-zero measurement from an instrument that has never been shown to
produce a non-zero reading is not evidence of absence."* Rev 1 of that probe
was discarded for exactly this reason. Making the instrument discriminating
*first*, then trusting it, is the whole discipline.

Run 2 varied the fill by frame index.

## Observations (run 2)

```
output attached: 1 output(s)
item.status: readyToPlay
seek 0.5s -> buffer 320x240 mean=78.82  after 0 tries
seek 2.0s -> buffer 320x240 mean=157.40 after 0 tries
seek 3.5s -> buffer 320x240 mean=93.39  after 0 tries
distinct fingerprints across 3 seeks: 3 of 3
```

## Answers

1. **`AVPlayerItemVideoOutput` is a usable observable.** It returns the
   actually-decoded frame for a composition-backed `AVPlayerItem`, and three
   different seek targets yield three distinguishable buffers.
2. **It works on a paused item that has only been seeked** — never played —
   and the buffer was available on the first attempt (`0 tries`) at every
   target. No run loop pumping or playback is required.
3. Buffer dimensions match the composition's `renderSize` (320x240).

## Consequences for M4b

- Frame-accurate scrubbing can be tested against the frame actually shown,
  rather than against `currentTime()`'s report of what was requested. M4a's
  `seekIsExact` and `jumpSeeksToMarkerTime` are documented as non-discriminating
  for this reason; M4b should give them a real observable.
- **The fixture needs a per-frame-varying content mode**, opt-in like `.tone`
  and `.noise` before it, because the default flat gray makes every
  frame-identity property unobservable. That is a task in the M4b plan, not an
  afterthought — the property is invisible without it.
- A fingerprint (mean sample value over a sparse stride) is enough to identify
  *which* frame is on screen. Nothing here needs pixel-exact comparison.
