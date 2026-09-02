# S1 — Keystroke monitoring API

**Question (spec §14):** Can global keystroke capture use
`NSEvent.addGlobalMonitorForEvents`, or does it require `CGEventTap` with an
Input Monitoring grant?

**Date:** 2026-09-02  ·  **macOS version:** 26.5.2  ·  **Status:** Resolved

## Observations

Measured with probe **revision 2**. Revision 1's results were discarded — see
"Probe defect" below.

| Condition | NSEvent keyDown | NSEvent mouseDown | CGEventTap keyDown | Tap created? |
|---|---|---|---|---|
| Input Monitoring **DENIED** | 0 | 0 | 0 | **failed** |
| Input Monitoring **GRANTED** | **0** | 3 | **23** | succeeded |

The result that matters is the bolded one: `NSEvent` global `keyDown` counted
**zero even with Input Monitoring granted**, while `CGEventTap` went from
failing outright to capturing 23 keystrokes.

## Recommendation

**Use `CGEventTap` with the Input Monitoring grant. Do not use
`NSEvent.addGlobalMonitorForEvents` for keystrokes.**

The two APIs are gated by *different TCC services*, which is the whole answer:

- `CGEventTap` → **Input Monitoring** (`kTCCServiceListenEvent`)
- `NSEvent.addGlobalMonitorForEvents` → **Accessibility** (`kTCCServiceAccessibility`)

This is confirmed by Apple developer-forum guidance as well as by the table
above: granting Input Monitoring did nothing for `NSEvent` because it is not
the permission that API reads. `NSEvent` would additionally have required
Accessibility — a broader, scarier grant that lets an app control the machine,
and a harder thing to ask a user for than "let this recorder see keystrokes".

Snitt should therefore call `CGRequestListenEventAccess()` and create a
`CGEventTap`. That is both the narrower permission and the better onboarding
story.

## Probe defect — why revision 1's data was thrown away

Revision 1 reported all zeros including `mouseDown`, which looked like a clean
"denied" result and was not. Two independent bugs:

1. It called `CGPreflightListenEventAccess()` — which only *reads* the current
   grant — and never `CGRequestListenEventAccess()`, the call that raises the
   prompt. No dialog ever appeared, so the "granted" condition could not be
   entered at all.
2. It ran a bare `RunLoop.main.run()` with no `NSApplication`. AppKit global
   monitors are delivered through the application event machinery, so without a
   running `NSApp` they never fire — which is why even `mouseDown` counted zero,
   despite mouse monitors historically needing no permission.

The lesson worth carrying: an all-zero measurement from an instrument that has
never been shown to produce a non-zero reading is not evidence of absence. Rev 2
was made discriminating first — able to show a positive — and only then trusted.

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
