# S1 — Keystroke monitoring API

**Question (spec §14):** Can global keystroke capture use
`NSEvent.addGlobalMonitorForEvents`, or does it require `CGEventTap` with an
Input Monitoring grant?

**Date:** 2026-09-02  ·  **macOS version:** 26.5.2  ·  **Status:** Blocked — awaiting human execution

## Observations

| Condition | NSEvent keyDown | NSEvent mouseDown | CGEventTap keyDown |
|---|---|---|---|
| Input Monitoring DENIED | | | |
| Input Monitoring GRANTED | | | |

## Recommendation

**AWAITING HUMAN EXECUTION — do not fill in without running the probe.**

## Consequences

**AWAITING HUMAN EXECUTION — do not fill in without running the probe.**

## How to run this probe

```bash
# Step 1: build (already done as part of scaffolding, but safe to re-run)
swift build

# Step 2: run WITHOUT Input Monitoring granted to the terminal app you're
# using (System Settings → Privacy & Security → Input Monitoring — make sure
# your terminal is NOT in the list, or is present but unchecked)
swift run S1KeystrokeProbe
# Immediately switch to another app (e.g. TextEdit) and type continuously
# for the full 15 seconds before the probe exits on its own.

# Step 3: grant Input Monitoring to your terminal app in
# System Settings → Privacy & Security → Input Monitoring, then re-run
swift run S1KeystrokeProbe
# Again type in another app for the full 15 seconds.
```

Observations to record, in order:

1. From the Step 2 run (Input Monitoring DENIED): the "NSEvent global
   keyDown events" count, the "NSEvent global mouseDown events" count, the
   "CGEventTap keyDown events" count, and whether the console printed
   "CGEventTap created successfully." or "CGEventTap creation FAILED".
   Enter these three counts into the "Input Monitoring DENIED" row above.
2. From the Step 3 run (Input Monitoring GRANTED): the same three counts.
   Enter them into the "Input Monitoring GRANTED" row above.
3. Confirm the "Input Monitoring granted" boolean printed at both the start
   and end of each run matches what System Settings shows — if it does not,
   note the discrepancy (macOS sometimes requires the app/terminal to be
   restarted after a permission change).
4. Once both rows are filled in, replace the "Recommendation" section with
   one of: "NSEvent suffices for keystrokes", "Input Monitoring is required
   for keystrokes; mouse events work without it", or another conclusion
   supported by the numbers — then fill in the four "Consequences" bullets
   (permission onboarding §4.10, App Store variant §4.3, conditional call
   sites §4.3, `--auto-trim` §8/D23) and change Status to `Resolved`.
