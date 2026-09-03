# S5 — Capture in the real client→IPC→app topology

**Question (spec §4.9, §13):** When a client whose parent is NOT Snitt asks
`Snitt.app` over a socket to capture, does the capture succeed using SNITT'S own
TCC grant?

**Why it matters:** Spike S3 showed a background process can capture, but both of
its runs inherited the terminal's grant. §4.9's thin-client architecture — the
whole reason the CLI does not call ScreenCaptureKit — depends on the app's grant
being what counts. If it is not, M2b needs a different design.

**Date:** 2026-09-02 · **macOS:** <version> · **Status:** AWAITING HUMAN EXECUTION

## Observations

| Condition | frames | nonBlack | Notes |
|---|---|---|---|
| Server inside Snitt.app, client outside | | | |
| Server run directly from the terminal (control) | | | |

## Recommendation

<Does §4.9's architecture hold? If capture fails or returns only black frames when
triggered by an unrelated client, say so plainly and state what M2b must do instead.>

## Consequences

- **Thin-client architecture (§4.9):** <validated / needs revision>
- **Socket location (§10):** <does the client need any special entitlement to connect>
- **What M2b builds next:** <unchanged / what changes>
