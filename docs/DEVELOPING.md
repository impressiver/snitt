# Developing Snitt

Snitt is a native macOS screen recorder built with SwiftPM. There is no Xcode
project file — `Package.swift` is the whole build definition, and the app
bundle is assembled by a script.

## What you need

- **macOS 26 (Tahoe) or later.** This is the deployment floor (§4.6, D77), not
  a preference: the code depends on concurrency annotations that only the
  macOS 26 SDK carries. It genuinely does not compile against the 15 SDK.
- **Xcode 26 or later**, for Swift 6.2 — `Package.swift` declares
  `swift-tools-version: 6.2`, which is where `.macOS(.v26)` exists.

```sh
swift --version        # expect 6.2 or newer
xcodebuild -version
```

Nothing else. No Homebrew packages, no linter to install, no `pod install`.

## Build and test

```sh
swift build            # the libraries and executables
./Scripts/run-tests.sh  # the full gate, ~63s, 1152 tests — prefer this
```

Both work from a clean checkout with no configuration.

### Read the summary line, not the exit status

**Prefer `./Scripts/run-tests.sh` over a bare `swift test`.** It does two
things by hand that are easy to forget:

- **It splits the run.** `SnittExportTests` costs 8.4s alone but adds ~34s when
  run beside `SnittAppTests` — both are AVFoundation-heavy and they contend.
  Measured: one invocation 88s, two invocations 63s, identical 1152 tests.
  Adding the other five targets to the app pass is free, so the split is one
  cut, not a general partitioning.
- **It checks the summary line and reconciles the totals**, so a crashed bundle
  or a mistyped filter fails the gate instead of passing quietly. A filter that
  matches nothing reports `Test run with 0 tests ... passed`; the totals not
  adding up to the package's test count is what catches that.

**`swift test` exits 0 when the test bundle segfaults.** It prints
`signal code 11` inline and then no summary at all. This has bitten this
project twice, most recently after adding a stored property to a public struct.

The only trustworthy signal is the final line:

```
✔ Test run with 1041 tests in 90 suites passed after 89.4 seconds.
```

If that line is absent, the run failed no matter what `$?` says. CI enforces
exactly this (`.github/workflows/ci.yml`).

## Running the app

`swift build` does **not** produce something you can run. The app is a bundle,
and the bundle is assembled by a script that also embeds the CLI, the MCP
server, and Sparkle:

```sh
./Scripts/make-app.sh          # runs swift build itself, then assembles build/Snitt.app
open build/Snitt.app
```

**Re-run this after any change you want to see on screen.** `swift build` and
`swift test` do not touch `build/Snitt.app`, so a green suite proves nothing
about what the running app does. Losing an hour to this is a rite of passage
here; skip it.

```sh
stat -f "%Sm" build/Snitt.app/Contents/MacOS/Snitt   # what you are actually running
```

### One-time: a stable signing identity

macOS ties TCC permission grants to an app's code signature. Ad-hoc signing
changes that signature on every build, so **macOS forgets Screen Recording
permission every time you rebuild** — which, for a screen recorder, means
re-granting permission constantly.

`make-app.sh` looks for a self-signed local certificate named
`Snitt Development`. If it is missing it falls back to ad-hoc and warns. Create
it once — it is local-only and never leaves your machine:

1. Open **Keychain Access**
2. **Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…**
3. Name: `Snitt Development`, Identity Type: **Self Signed Root**,
   Certificate Type: **Code Signing**
4. Create, then Done

Run `./Scripts/signing-identity.sh` to check; it prints these instructions if
the certificate is missing. Background in
`docs/superpowers/notes/signing.md`.

Release builds select a real Developer ID via `SNITT_SIGN_IDENTITY`. Nothing
secret lives in this repo, and the release path is
`docs/superpowers/notes/release-runbook.md`.

### Permissions it will ask for

Screen Recording is granted in **System Settings ▸ Privacy & Security**;
the microphone and speech recognition prompt on first use, and both are
opt-in — Snitt records neither unless you turn them on. Input-event logging is
also opt-in, off by default.

Recordings land in `~/Documents/Snitt` by default, as `.snitt` bundles.

## The CLI and the MCP server

Both ship inside the app bundle rather than on your `PATH`:

```sh
build/Snitt.app/Contents/Helpers/snitt --help
build/Snitt.app/Contents/Helpers/snitt-mcp     # speaks MCP over stdio
```

They are thin clients: they talk to the running app over a Unix socket and do
no capture themselves (§4.9). If the app is not running, they start it.

To register the MCP server with agent hosts on this machine:

```sh
build/Snitt.app/Contents/Helpers/snitt setup --apply
```

**Rebuild the bundle after changing CLI or MCP code too.** The embedded copies
are what `snitt setup` registered; `.build/debug/snitt-mcp` being fresh does
not help you if the host launches the bundled one.

## Traps that will cost you an hour

Each of these has actually happened here.

**A stale incremental build after changing a public struct.** Adding a stored
property changes the type's layout, and SwiftPM does not always recompile every
dependent. The symptom is a segfault at a random test with no crash report,
which survives reverting the change line by line. The fix is `rm -rf .build`.

**`Contents/MacOS` is case-insensitive.** Copying a CLI named `snitt` into
`Contents/MacOS/` replaces the app binary `Snitt`. The helpers live in
`Contents/Helpers/` for this reason, and a test pins it.

**A Unix socket file outlives its process.** `FileManager.fileExists` on the
socket path is not a liveness check — connect to it instead.

**`timeout(1)` does not exist on macOS.** Neither does `grep -P`.

## Where things are

| Path | |
|---|---|
| `Sources/SnittDocument` | the `.snitt` bundle format, EDL, event log — no AV, no UI |
| `Sources/SnittCapture` | ScreenCaptureKit, the recorder, capture health |
| `Sources/SnittExport` | composition, export, waveforms, transcription helpers |
| `Sources/SnittAutomation` | the wire protocol, CLI parsing, MCP bridge |
| `Sources/SnittApp` | the app: menu bar, editor, automation host |
| `Sources/snitt-cli`, `Sources/snitt-mcp` | the two thin clients |
| `Scripts/` | bundle assembly, signing, appcast, icons |
| `docs/superpowers/specs/` | the design spec — **the binding authority** |
| `docs/superpowers/notes/field-notes.md` | what went wrong and what it cost |

## Before you open a pull request

CI runs hygiene on Linux and builds plus tests on macOS 26
(`.github/workflows/ci.yml`). To match it locally:

```sh
swift build -Xswiftc -warnings-as-errors    # no warning group is exempt
swift test
```

Work goes on a branch and through a PR, never straight to `main`.

The spec in `docs/superpowers/specs/` is the authority, and decisions are
numbered (D1…). If you change behaviour the spec describes, amend the decision
in the same change — a test (`SpecConformanceTests`) checks that references
resolve, and `field-notes.md` records the times the plan and the code drifted
apart anyway.
