# S5 — Capture in the real client→IPC→app topology

**Question (spec §4.9, §13):** When a client whose parent is NOT Snitt asks
`Snitt.app` over a socket to capture, does the capture succeed using SNITT'S own
TCC grant?

**Why it matters:** Spike S3 showed a background process can capture, but both of
its runs inherited the terminal's grant. §4.9's thin-client architecture — the
whole reason the CLI does not call ScreenCaptureKit — depends on the app's grant
being what counts. If it is not, M2b needs a different design.

**Date:** 2026-09-02 · **macOS:** <version> · **Status:** AWAITING HUMAN EXECUTION

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

| Condition | frames | nonBlack | Notes |
|---|---|---|---|
| Server = S5Server.app (own grant, launched via open), client from terminal | | | |
| Server run directly from the terminal (control) | | | |

## Recommendation

<Does §4.9's architecture hold? If capture fails or returns only black frames when
triggered by an unrelated client, say so plainly and state what M2b must do instead.>

## Consequences

- **Thin-client architecture (§4.9):** <validated / needs revision>
- **Socket location (§10):** <does the client need any special entitlement to connect>
- **What M2b builds next:** <unchanged / what changes>
