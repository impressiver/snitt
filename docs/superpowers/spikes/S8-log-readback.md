# S8 — Reading our own logs back

**Question (M5):** §12 requires `snitt diagnostics export` to bundle "recent
logs". That only works if a process can read its own `os_log` entries back.
Can it, and from where?

**Date:** 2026-09-05 · **macOS:** 26.5.2 · **Status:** Resolved

## Observations

A throwaway test wrote two entries under a private subsystem, waited for the
logging system to flush, then read back through `OSLogStore`.

```
Q1 OSLogStore(scope: .currentProcessIdentifier): OK
Q2 entries in last 60s: total=3, ours=2
Q3 sample: [com.impressiver.snitt.spike/probe] level=4 SPIKE marker 1859941…
Q4 OSLogStore(scope: .system): OK
```

## Answers

1. **Readable.** `OSLogStore(scope: .currentProcessIdentifier)` works without
   any entitlement, and entries expose `subsystem`, `category`, `level` and
   `composedMessage` — enough to filter to Snitt's own subsystems and to
   distinguish §12's error categories.
2. `position(date:)` + `getEntries(at:)` gives a time-bounded window, which is
   what "recent logs" needs.

## The consequence that shapes the milestone

**`.currentProcessIdentifier` sees only the calling process.** `snitt
diagnostics export` runs in the CLI, which is a *different process* from
Snitt.app — so a CLI-side implementation would bundle the CLI's own handful of
log lines and none of the app's. The result would look like a working feature
and contain nothing useful.

So **diagnostics must be produced in the app and returned over the automation
socket**, exactly as trim and export are (§4.9, M3c). The CLI asks; the app
answers. This is the same thin-client rule that spike S5 established for
capture, arriving for a different reason: there it was TCC, here it is process
scope.

## A result deliberately not relied upon

`OSLogStore(scope: .system)` also succeeded here. That is **not** load-bearing
and should not be built on: this ran from a test binary launched by a developer
shell, and a notarized, sandboxed, or hardened-runtime app is a different
security context. Filtering the whole system log to find our own entries would
also be far more work than reading our own process's. Recorded so the next
person does not "discover" it and take a dependency on it.
