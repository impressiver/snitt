# S5 — Capture in the real client→IPC→app topology

**Question (spec §4.9, §13):** When a client whose parent is NOT Snitt asks
`Snitt.app` over a socket to capture, does the capture succeed using SNITT'S own
TCC grant?

**Why it matters:** Spike S3 showed a background process can capture, but both of
its runs inherited the terminal's grant. §4.9's thin-client architecture — the
whole reason the CLI does not call ScreenCaptureKit — depends on the app's grant
being what counts. If it is not, M2b needs a different design.

**Date:** 2026-09-03 · **macOS:** 26.5.2 · **Status:** Resolved

**Defects fixed (2026-09-03):**
- Permission request was missing: probe called only `CGPreflightScreenCaptureAccess()` (which reads the current grant) and never `CGRequestScreenCaptureAccess()` (which raises the system dialog). Without the Request call, the system never prompted, and the capture silently failed. This is the third occurrence of this defect in this project.
- Log path was TCC-protected: writing to `~/Desktop` is gated by the Files-and-Folders service, silently defeating reads from both shell and the app. Changed to `/tmp/snitt-s5.log` so both the bundled app and a plain shell can access the results.

## Why the probe needs its own app bundle

Initial design attempted to copy the probe into `build/Snitt.app/Contents/MacOS/` and run it
from there, assuming it would inherit Snitt's code identity and TCC grant. It does not.
Inspection shows:

```
$ codesign -dv build/Snitt.app/Contents/MacOS/S5RealTopology
Identifier=S5RealTopology-555549449311a675b26d33e0bacd126f01439b20
flags=0x2(adhoc)
```

versus the app's `Identifier=com.impressiver.snitt`. TCC keys on code identity, not
filesystem location. A binary copied into an app bundle but not signed as part of it
retains its own ad-hoc identity and receives no share of the parent's grant. This
means the probe would have fallen back to the launching terminal's grant — exactly
the flaw that made S3's result unable to answer the question it was testing.

**Fix:** Give the probe its own bundle identity `com.impressiver.snitt.s5probe` via
`make-s5-probe-app.sh`. When launched via LaunchServices (the `open` command), the
app itself becomes the responsible process — not the terminal. Only then can it hold
its own TCC grant, which is the analog of §4.9's claim: an app with a grant driven
by a caller with none.

## How to run this probe

```bash
# 1. Build and sign the probe as its own app
./Scripts/make-s5-probe-app.sh

# 2. Launch it through LaunchServices — NOT from a shell. Only then is the app
#    itself the responsible process; from a shell the terminal would be.
rm -f /tmp/snitt-s5.log
open build/S5Server.app --args serve
#    Grant Screen Recording to "S5Server" when macOS prompts, then relaunch it
#    (macOS requires a relaunch after the grant is toggled).

# 3. From a terminal — a parent with NO screen-recording grant of its own —
#    ask the server to capture:
./.build/debug/S5RealTopology ask

# 4. Read what the server recorded:
cat /tmp/snitt-s5.log

# 5. Control run: the same probe with the TERMINAL as responsible process.
#    This is what S3 measured; it should succeed, and is only a baseline.
./.build/debug/S5RealTopology serve   # in one terminal
./.build/debug/S5RealTopology ask     # in another
```

## Observations

Executed by a human on 2026-09-03. Three sequential runs of the same `S5Server.app`
(`com.impressiver.snitt.s5probe`, signed with the stable "Snitt Development" identity,
launched via `open` so LaunchServices — not the terminal — is the responsible process).
The client `ask` ran from a terminal.

| Run | Server state | Log output | frames | nonBlack |
|---|---|---|---|---|
| 1 | first launch, no grant | `CGRequestScreenCaptureAccess() returned: false` → `DENIED` | — | — |
| 2 | relaunched after the human granted S5Server | `Screen Recording already granted at start` | — | — |
| 3 | same process as run 2, client asked | `S5 server handled a request` | **114** | **110** |

The client printed `S5 client got: frames=114 nonBlack=110`.

**The negative reading is what makes this trustworthy.** Run 1 shows the server holding
no grant and being refused. Run 2 shows the same bundle, unchanged and re-signed with the
same identity, reporting the grant it had just been given. Run 3 captures. The instrument
was demonstrated to produce BOTH readings before its positive was believed — the standard
S1's postmortem set after an all-zero measurement, from an instrument never shown to read
non-zero, was mistaken for evidence of absence.

Four of 114 frames were black: stream warm-up at `startCapture`, not a defect. `SCStream`
delivers its first frames before the first composite is ready.

The terminal control run (step 5 of the procedure) was not needed. It would have shown the
terminal's own grant working, which S3 already established. The within-app negative→positive
transition above is the stronger control, because it varies the grant while holding the
code identity fixed.

## Recommendation

**§4.9's thin-client architecture holds. Build M2b as planned.**

An app holding its own Screen Recording grant captures real content when told to over a
Unix socket by a client that holds no grant of its own. The client contributed nothing but
a byte on a socket; the capture ran entirely in the server's process, under the server's
identity. That is precisely the shape M2b's CLI and MCP server take.

This also settles what S3 could not. S3's two runs both inherited the terminal's grant, so
its success was equally consistent with "the app's grant is what counts" and with "whatever
launched it is what counts". Run 1 here excludes the second reading: the server was denied
while the terminal that later drove it was unaffected.

## Consequences

- **Thin-client architecture (§4.9): validated.** The CLI and MCP server stay thin and
  never call ScreenCaptureKit. `Snitt.app` holds the single grant and performs all capture.
- **Socket location (§10): no special entitlement needed.** An ordinary client process
  connected to a Unix domain socket and was served, with no entitlement on either side.
  The production socket still moves to Application Support rather than `/tmp`, which is
  world-writable and squattable; nothing observed here argues against that.
- **What M2b builds next: unchanged.** Tasks 6-9 — the socket server and client, the app
  host, the `snitt` CLI, and the MCP server — proceed as written.
- **One grant per app identity, and it needs a relaunch.** `CGRequestScreenCaptureAccess()`
  returned `false` even as the human granted it in the dialog; the grant took effect only
  on the next launch. Snitt's own onboarding (§4.10) must expect this and tell the user to
  relaunch, rather than reporting a denial that is really a not-yet.

## Cleanup

`S5Server.app` holds a Screen Recording grant on the development machine. It is throwaway
spike infrastructure: revoke it in System Settings → Privacy & Security → Screen & System
Audio Recording, and delete `build/S5Server.app`, once nothing else needs it.
