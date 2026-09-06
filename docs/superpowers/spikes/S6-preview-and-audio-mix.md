# S6 — Preview attachment and the audio mix

**Questions (M4):**
1. Does `AVPlayerItem` accept the composition `CompositionBuilder` actually
   produces, or does it reject it? §9's preview/export sharing guarantee has
   been assumed through five milestones and never exercised.
2. Can an `AVAudioMix` express the EDL's per-track mute and gain against the
   composition's audio tracks — the precondition for M3d's ruling that the mix
   must live in `BuiltComposition`, not in the preview?

**Date:** 2026-09-04 · **macOS:** 26.5.2 · **Status:** Resolved

## Method

A throwaway test inside `SnittExportTests`, deliberately *not* a standalone
script: it drives the real `CompositionBuilder.build(bundle:edl:scale:)` output
rather than a hand-built approximation, so it answers "does *our* composition
play" instead of "does *a* composition play". A standalone `swiftc` binary was
tried first and abandoned — top-level `await` let the process exit before the
work ran, and `AVPlayerItem` needs a real run loop.

## Observations

```
built: duration=3.0 renderSize=(320.0, 240.0)
composition audio tracks: 2
Q2 audio mix inputParameters: 2
Q1 AVPlayerItem.status after 0.1s: readyToPlay
Q1b duration=3.0 presentationSize=(320.0, 240.0)
Q2b audioMix attached=true params=2
```

## Answers

1. **Yes.** `AVPlayerItem(asset: built.composition)` with
   `item.videoComposition = built.videoComposition` reaches `.readyToPlay` in
   ~0.1s. `presentationSize` equals the composition's `renderSize`, and
   `item.duration` equals the trimmed duration. **§9's shared-builder guarantee
   holds in practice, not just on paper.**
2. **Yes.** `AVMutableAudioMixInputParameters(track:)` binds to the
   composition's own audio tracks and `setVolume(_:at:)` expresses mute (0.0)
   and gain. The mix attaches to the player item. M3d's ruling is actionable.

## Constraint discovered, binding on M4's design

Under Swift 6 strict concurrency — which this project enforces at zero warnings
— **`AVPlayerItem` is main-actor isolated** (`init(asset:)` cannot be called
off the main actor) and **`AVAudioMix` is non-Sendable** (it "cannot exit
main actor-isolated context").

Two consequences:

- Every preview type M4 introduces is `@MainActor` by construction, not by
  preference.
- Adding an `AVAudioMix` to `BuiltComposition` extends the surface its
  `@unchecked Sendable` annotation covers. That annotation's soundness rests on
  a documented invariant — `build` returns objects it has finished mutating and
  never touches again. The invariant must be restated to cover the mix, and the
  mix must be constructed inside `build` and never mutated afterwards.

## Consequences

- M4 can attach `BuiltComposition` directly to an `AVPlayerItem`. No adapter,
  no second derivation, no `AVVideoCompositionCoreAnimationTool` (V5, §9).
- The audio mix belongs in `CompositionBuilder.build`, alongside the video
  composition, so preview and export receive identical audio treatment. Export
  currently ignores `trackStates`; once the mix exists, both consume it.
