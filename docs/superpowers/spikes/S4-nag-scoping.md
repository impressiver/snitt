# S4 — Is the monthly re-consent prompt scoped per-app or per-path?

**Question (spec §14):** macOS 15 shows a recurring monthly screen-recording
re-consent prompt to apps that bypass `SCContentSharingPicker`. Is that charged
to the *app* (any `SCShareableContent` call taints it) or to the *recording
path* (only bypass-path recordings count)?

**Why it matters:** §4.11's cached-target instant capture and §5.2's residual
justification for adopting the picker both assume per-path scoping. If scoping
is per-app, then picker-driven sessions are prompted too once any hotkey
recording ships, and picker adoption buys almost nothing.

**Date opened:** 2026-09-02 · **Status:** Open — long-running observation

## Method

`swift run S4NagObservation enumerate` logs one `SCShareableContent` call with a
timestamp. Use the app normally. When the monthly prompt appears, immediately run
`swift run S4NagObservation note-prompt` to timestamp it.

## Observations

| Date | Event | Notes |
|---|---|---|
| | | |

## Interpretation guide — fill in when the data arrives

- **Prompt fires even in months containing only picker-driven recordings** →
  scoping is per-app. §4.11's design still stands on its own merits (a monthly
  prompt still beats a per-recording picker) but §5.2 must stop claiming the
  picker helps, and D38's justification for picker adoption weakens to
  "API-correctness only".
- **Prompt fires only in months containing a bypass-path recording** → scoping
  is per-path. The cached-target hybrid is genuinely a hybrid, and picker
  adoption keeps its value for manual recording.

## Status

**AWAITING OBSERVATION — do not fill in the conclusion without data.** This
spike takes weeks by construction; an empty table is the correct state until the
prompt has actually been seen at least twice.
