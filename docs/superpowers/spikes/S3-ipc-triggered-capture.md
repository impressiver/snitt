# S3 — IPC-triggered capture

**Question (spec §14):** Does ScreenCaptureKit capture correctly when
initiated from a background, non-foreground app? What happens when the screen
is locked or no user is logged in?

**Date:** 2026-09-02  ·  **macOS version:** 26.5.2  ·  **Status:** Blocked — awaiting human execution

## Observations

| Condition | Frames received | Non-black frames | Notes |
|---|---|---|---|
| Foreground (control) | | | |
| Background, detached | | | |
| Screen locked | | | |

## Recommendation

**AWAITING HUMAN EXECUTION — do not fill in without running the probe.**

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
