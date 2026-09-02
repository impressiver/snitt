# S3 — IPC-triggered capture

**Question (spec §14):** Does ScreenCaptureKit capture correctly when
initiated from a background, non-foreground app? What happens when the screen
is locked or no user is logged in?

**Date:** 2026-09-02  ·  **macOS version:** 26.5.2  ·  **Status:** Partially resolved — background capture confirmed; locked-screen case and production IPC topology still unrun

## Observations

| Condition | Frames received | Non-black frames | Notes |
|---|---|---|---|
| Foreground (control) | 306 | 142 | ~61 fps over 5s, consistent with the 60 fps config. `isFrontmost` reported **false** — see Limitations. |
| Background, detached (`nohup`) | 295 | 102 | Capture works. No permission failure, no error. |
| Screen locked | *(not run)* | | Still outstanding. |

Both runs saw 1 display and 58 windows, so `SCShareableContent` enumerated
normally in each.

## Recommendation

**Background capture works.** A detached, non-frontmost process receives frames
containing real (non-black) screen content, with no permission error and no
degradation to blank output. Nothing here invalidates the thin-client
architecture in §4.9, and M2 is not blocked on this result.

That conclusion is narrower than the probe's framing suggests, for two reasons
recorded under Limitations below. It should be read as "a background process is
not categorically prevented from capturing", not as "the production topology is
verified".

## Limitations of this run — read before relying on the result

1. **The frontmost/background comparison was not actually established.**
   `Process is frontmost: false` in BOTH runs. A Swift Package Manager binary
   launched from a terminal is never the frontmost application — the terminal
   is. So the "control" and the "background" run differed only in whether the
   process was detached via `nohup`, not in frontmost status. The useful claim
   that survives is that a non-frontmost, non-bundled process captures real
   content.

2. **Both runs inherited the terminal's TCC grant.** The responsible process was
   Terminal in both cases (§4.9). The production topology is different: a CLI
   whose parent is an arbitrary agent host, talking over IPC to `Snitt.app`,
   which holds its own grant. That path is unexercised here and remains the
   thing M2 actually depends on.

3. **The non-black heuristic is coarse.** The probe samples one byte per 32nd
   row — effectively the leftmost pixel column — so a dark region at the screen's
   left edge reads as "black". The 33-46% non-black rates should NOT be read as
   "half the frames were empty". They are consistent with either the heuristic's
   crudeness or with ScreenCaptureKit delivering repeated/idle frames, and this
   run cannot distinguish the two.

   Note this is suggestive of the idle-frame behavior that the `.complete`
   frame-status guard in `CaptureSession.isCompleteFrame` was added to handle —
   but it is not evidence for it, and should not be cited as such.

## Consequences

**AWAITING HUMAN EXECUTION — do not fill in without running the probe.**

## How to run this probe

```bash
# Step 1: build (already done as part of scaffolding, but safe to re-run)
swift build

# Step 2: foreground baseline (the control run)
swift run S3IPCCaptureProbe foreground
# Let it run to completion (~5 seconds of capture); it prints results and exits.

# Step 3: background, detached — no foreground activation
nohup swift run S3IPCCaptureProbe background > /tmp/s3-bg.log 2>&1 &
sleep 20
cat /tmp/s3-bg.log

# Step 4: screen-locked case
nohup swift run S3IPCCaptureProbe background > /tmp/s3-lock.log 2>&1 &
# Immediately lock the screen: Ctrl+Cmd+Q
# Wait ~20 seconds, then unlock and read the log:
cat /tmp/s3-lock.log
```

Note: if screen recording permission has not yet been granted to the
terminal/app running the probe, the first run will trigger (or fail on) the
macOS Screen Recording consent prompt — grant it via System Settings →
Privacy & Security → Screen Recording before re-running Step 2, otherwise
every subsequent condition will report a capture failure that reflects
missing permission, not the background/lock behavior being tested.

Observations to record, in order:

1. From Step 2 (foreground control): "Frames received" and "Non-black
   frames" from the "--- RESULTS ---" block, plus whether
   "Process is frontmost" printed `true`. Enter frames/non-black frames into
   the "Foreground (control)" row.
2. From Step 3 (background, detached): the same two counts from
   `/tmp/s3-bg.log`, plus whether "Process is frontmost" printed `false` and
   whether the run completed normally or exited with a `RESULT: capture
   FAILED with: ...` error. Enter counts into the "Background, detached" row
   and any error text into its Notes cell.
3. From Step 4 (screen locked): the same two counts from
   `/tmp/s3-lock.log`, and specifically note in the Notes cell whether frames
   continued to arrive while locked, went to zero non-black frames while
   still counting frames received (i.e. black frames), the process errored
   out, or the process appeared to be suspended (log stops updating and only
   resumes/completes after unlock). Enter counts into the "Screen locked"
   row.
4. Once all three rows are filled in, replace the "Recommendation" section
   with a plain statement of whether the thin-client architecture in §4.9
   holds — if background or locked capture is black or fails, say so
   explicitly and state what M2 must do instead — then fill in the three
   "Consequences" bullets (thin-client architecture §4.9, agent error
   handling §11, capture health checks §12.1) and change Status to
   `Resolved`.
