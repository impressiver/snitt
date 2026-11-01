# Plan refinement ledger — snitt-welcome-screen

artifact: this file ("The plan" below)
slug: snitt-welcome-screen
session: d42cd016-2375-43b3-a942-7012aa6a077d
opened: 2026-10-30

## Run parameters

- tier: focused pass. 4 personas, cross-exam only on contested Important
  items, 1 pass unless something opens a new axis.
- consent mode: auto-accept verified factual corrections only; every design
  tradeoff goes to the menu.
- model-policy: main line Opus, personas Sonnet.

## Problem

A bare launch raises a modal `NSOpenPanel`. Three things wrong with it:

1. It presumes you came to open an existing file.
2. It is modal, so it blocks everything until answered.
3. On a genuine first launch there is nothing to open, so a new user meets a
   file picker aimed at a folder containing no `.snitt` files.

There is also no getting-started help, no tips, and no visibility into whether
the permissions Snitt needs are actually granted.

## Settled by the product owner (do not re-litigate the *what*)

1. **Welcome replaces `EmptyDocumentWindow`.** One front door. `File ▸ New`
   shows Welcome too; Welcome carries the drop-anywhere target
   `EmptyDocumentWindow` has today; that type is deleted.
2. **Getting-started shows until there is a recording**, then quick tips.
   Derived from state, not a one-shot flag.
3. **A Dock click with no windows shows Welcome**, replacing `DockReopen`'s
   reopen-most-recent and its no-recents notification.
4. **Recents whose bundle no longer exists are hidden.**
5. **A permissions section**, showing what is missing and how to allow it.

## Phase 2 — grounding

| ID | Claim | Verdict | Evidence |
|----|-------|---------|----------|
| G1 | The bare-launch seam is one call site | **CONFIRMED** | `main.swift:198` `offerToOpenADocumentIfLaunchedBare` defers one runloop pass, calls `LaunchOpenPrompt.decide(...)`, and on `.prompt` calls `openDocument(nil)`. The defer is load-bearing: `application(_:open:)` can arrive either side of `applicationDidFinishLaunching`. |
| G2 | `LaunchOpenPrompt`'s four suppressions apply unchanged to a window | **CONFIRMED** | `LaunchOpenPrompt.swift`: `.agentLaunch` (a panel "steals focus" and blocks the main actor an agent needs), `.recording` (§4.11, an app launched into recording stays silent), `.documentAlreadyOpening`, `.windowAlreadyOpen`. A window is subject to all four for the same reasons; `.agentLaunch` arguably more so. |
| G3 | `EmptyDocumentWindow` already is the Import half | **CONFIRMED** | 135 lines: a `VideoDropView` over the whole window plus "Choose Video…" (`NSOpenPanel` filtered to `ImportableMedia.types`), calling back `onVideos` and closing itself. Reused by `main.swift:506` for `File ▸ New`. Single-instance already ("Reuse rather than stack"). |
| G4 | Recordings reach the recents list, so one list covers "created or opened" | **CONFIRMED** | `DocumentOpener.swift:200` notes the URL after a successful `show()`, and a finished recording opens through `DocumentOpener`. Also noted on relocate (`EditorWindowController.swift:4094`). |
| G5 | Recents are NOT existence-filtered today | **CONFIRMED** | `RecentDocuments.urls()` returns `NSDocumentController.shared.recentDocumentURLs` raw, and `buildMenu()` lists them unfiltered. So decision 4 is new work, not a setting. |
| G6 | All three services expose a NON-PROMPTING status read | **CONFIRMED** | `ScreenRecordingAccess.isGranted()` = `CGPreflightScreenCaptureAccess()`, documented "Reads the current grant without raising any dialog"; `MicrophoneAccess.isGranted()` = `AVCaptureDevice.authorizationStatus(for: .audio) == .authorized`; `InputMonitoringAccess.isGranted()` = `CGPreflightListenEventAccess()`. |
| G7 | Reading status does not trip the access-conformance rule | **CONFIRMED** | `AccessConformanceTests.swift:197` flags a FILE that contains `CGPreflight<Service>Access` without `CGRequest<Service>Access`. Calling `ScreenRecordingAccess.isGranted()` contains neither string, so the rule is satisfied; that type is the sanctioned route and its own comment says callers "should check this first, rather than calling `CGPreflightScreenCaptureAccess()` directly". |
| G8 | Requesting a permission at launch would violate a documented decision | **CONFIRMED** | `PermissionLadder.apply`: *"First use of the feature that needs it — never at launch."* So the welcome screen READS status and links out; it must never call `ensureGranted`. |
| G9 | Two of the three grants only take effect on the NEXT LAUNCH | **CONFIRMED** | `ScreenRecordingAccess`: *"`CGRequestScreenCaptureAccess()` returns `false` even when the user grants permission... the grant takes effect on the NEXT launch. Callers must report that as 'relaunch Snitt', not as a denial (spec §4.10). Verified on macOS 26.5.2 during spike S5."* `InputMonitoringAccess` says the same. `MicrophoneAccess` explicitly does NOT need a relaunch: *"AVFoundation reports Microphone authorization live."* |
| G10 | Status checking must not enumerate windows | **CONFIRMED, and the hazard is real** | `ConsentExplainer` exists solely to apologise for a periodic re-consent prompt macOS charges for `SCShareableContent` enumeration, "roughly monthly". `isGranted()` preflights and never enumerates, so it does not trigger it. A status check built on enumeration would fire that prompt on every launch. |
| G11 | The Settings deep links already exist, per service | **CONFIRMED** | `PermissionOnboarding.settingsURL(for:)` returns `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` / `?Privacy_Microphone` / `?Privacy_ListenEvent`. `Service` also carries `displayName` and a `why` string per service. |
| G12 | Only Screen Recording is unconditional | **CONFIRMED** | `PermissionOnboarding.Service.why`: microphone is needed because *"You turned on voiceover"*, input monitoring because *"You turned on input logging"*. Both are opt-in, governed by `MicrophoneSettings` and `EventLoggingSettings`. |
| G13 | A tip that cites a shortcut has a source of truth | **CONFIRMED** | `AppShell.helpMenuItem` builds Keyboard Shortcuts from `KeyboardShortcutRegistry`, on the stated rule that the dialog *"cannot describe a binding that does not exist, and a binding cannot exist undocumented"*. |
| G14 | The one-shot-flag precedent and key convention | **CONFIRMED** | `ConsentExplainer` uses `com.impressiver.snitt.consentExplainerShown`. Every key is `com.impressiver.snitt.<camelCase>`. No first-launch key exists yet. |

## The plan

Follows the repo's established split — a pure decision type plus a thin
AppKit window — the shape `LaunchOpenPrompt` and `DockReopen` already use so
that the decisions are testable without a window server.

### `WelcomeContent` (pure, `Sources/SnittApp/`)

- `guidance(hasRecordings: Bool) -> Guidance`, where
  `Guidance = .gettingStarted | .quickTips([Tip])`. Decision 2 means this is
  derived from whether there is anything in the (filtered) recents list, so
  there is no flag to get stuck.
- `recents(from: [URL], fileManager: FileManager) -> [Entry]` — existence
  filtered (G5 is new work), capped, most-recent-first.
- `permissionRows(...) -> [PermissionRow]` — one row per service that is
  actually relevant: Screen Recording always, Microphone only when
  `MicrophoneSettings` is on, Input Monitoring only when `EventLoggingSettings`
  is on (G12). Each row carries the service, whether it is granted, and
  whether a grant implies a relaunch (G9: yes for screen recording and input
  monitoring, no for microphone).
- Tips that cite a shortcut read `KeyboardShortcutRegistry` (G13).

### `WelcomeWindow` (thin AppKit, `Sources/SnittApp/`)

Guidance section, permission rows with an "Open Settings…" per missing one
(via `PermissionOnboarding.settingsURL(for:)`, G11), recents list, `Open…`
and `Import Video…` buttons, a drop target accepting both `.snitt` bundles
and `ImportableMedia` video, single-instance, and self-closing when a
document opens from it — all behaviours `EmptyDocumentWindow` already has.

**Reads status only. Never calls `ensureGranted` (G8).**

### Wiring

- `LaunchOpenPrompt.decide` keeps all four suppressions (G2). Its `.prompt`
  case is renamed `.welcome` and its doc comment rewritten, rather than left
  arguing for an Open panel.
- `offerToOpenADocumentIfLaunchedBare` shows Welcome instead of
  `openDocument(nil)`.
- `applicationShouldHandleReopen` shows Welcome; `DockReopen` and its
  no-recents notification retire.
- `File ▸ New` shows Welcome; `EmptyDocumentWindow` is deleted.

### PRs

- **A** — `WelcomeContent` plus tests. No UI, no behaviour change, lands green.
- **B** — `WelcomeWindow`, the bare-launch swap, `File ▸ New`, and deleting
  `EmptyDocumentWindow`. The behaviour change, kept atomic so there is never
  an interim state with two front doors.
- **C** — Dock reopen, retiring `DockReopen`. Separable; could fold into B.

## Phase 3 — Important findings (candidates for the panel)

- **I1.** Deleting `EmptyDocumentWindow` deletes a tested type. Its tests need
  rehoming or retiring, and `VideoDropView`'s "declines clicks so the button
  underneath still works" behaviour has to survive the move into a busier
  window with several controls.
- **I2.** Decision 2 derives first-run guidance from "has recordings". A user
  who deletes all their recordings reverts to getting-started. Defensible, but
  it is a consequence nobody chose explicitly.
- **I3.** The permissions section is the one part that can actively harm: a
  wrong implementation either fires TCC prompts at launch (G8), triggers the
  monthly re-consent (G10), or shows red crosses for features the user never
  enabled (G12). All three are avoidable by construction and all three need
  pinning.
- **I4.** `.agentLaunch` matters more for a window than for a panel: a window
  that steals focus behind an agent's work is worse than a modal panel that
  at least blocks obviously. The existing suppression covers it, but nothing
  currently proves a welcome window respects it.

## Decision log

_(appended as the Decider rules)_

### Added during the panel run

| ID | Claim | Verdict | Evidence |
|----|-------|---------|----------|
| G15 | Snitt is permanently `.regular`, so a Dock click with no windows is a real and common gesture | **CONFIRMED** | `AppShell.install` calls `app.setActivationPolicy(.regular)` unconditionally. Its doc comment records that Snitt was `.accessory` through M5 with the editor promoting and demoting, and that this came from misreading §4.11's "record without opening a window" as "have no application shell" — *"One is about what a keystroke does; the other is about what the app is."* It also states §4.11 is unaffected: *"the hotkey and status item still record with no window. A Dock icon does not require a window."* Supports decision 3. |

## Phase 7 — persona returns, verified by the Decider

- **W1 — CONFIRMED, and it corrects my own G13.** `KeyboardShortcutRegistry.Menu`
  is `{file, edit, view, playback}` (`:32-37`) — editor menu items only. The
  global record hotkey is a separate system: `HotkeyAction.record`
  (`HotkeySettings.swift:14`), read via `HotkeySettings.load(_:)[.record]`
  (subscript at `:59`), rendered by `HotkeyCombination.displayString`
  (`:247`). It is user-rebindable through the Settings recorder button, so a
  tip hardcoding ⌥⌘5 misreports it for anyone who changed it. G13 was right
  that the registry exists and wrong to imply it sources this. Carried by
  Product/UX.
- **W2 — CONFIRMED.** `KeyboardShortcutRegistry` is `@MainActor`
  (`:57`), `LaunchOpenPrompt` carries no isolation. Referencing the registry
  from `WelcomeContent` would force `@MainActor` onto it and break the
  pure/thin split the plan is built on. Carried by the Principal Engineer.
  **W1 and W2 compose:** `HotkeySettings` is a plain
  `public struct ... Sendable, Equatable` (`:44`), not isolated, so switching
  the tip's source to it satisfies both at once.
- **W3 — CONFIRMED.** The plan named no refresh mechanism for the permission
  rows, and there is no precedent to copy: zero `NotificationCenter` or
  `addObserver` in `EditorWindowController`, `SettingsWindowController` or
  `EmptyDocumentWindow`, and zero `didBecomeActive` anywhere in `Sources/`.
  The sharper half is a consequence of G9: a refresh-on-reactivate re-reads
  `isGranted()`, which cannot reflect a Screen Recording or Input Monitoring
  grant until the next process launch, so it would show nothing changed
  immediately after the user granted it — and silence reads as "it did not
  work". Carried by the Principal Engineer.
- **W4 — CONFIRMED. A correctness hole the plan never addressed.**
  `applicationShouldHandleReopen` is `guard !flag else { return true }` then
  `DockReopen.handle(...)` unconditionally (`main.swift:733-745`) — no
  `isRecording`, no `launchedByAgent`. `DockReopen.handle` takes no such
  parameter either. So routing the Dock path to a window that activates
  (`NSApp.activate(ignoringOtherApps:)`, as `EmptyDocumentWindow.show` does
  by default) would pop Welcome over a live or agent-initiated recording,
  which §4.11 requires stay silent. This is I4's hazard on a path the plan
  left out. Carried by Red team; axis no other persona covered.
- **W5 — CONFIRMED.** `Tests/SnittAppTests/DockReopenTests.swift` holds two
  suites: `DockReopenTests` calls `DockReopen.handle` directly (`:35`, `:54`),
  so deleting the type is a COMPILE break, not a test failure; and
  `AppDelegateReopenTests` asserts `openWindowCount == before + 1` after a
  Dock click (`:121`), i.e. exactly the behaviour decision 3 removes. The
  plan's PR C said only "retiring `DockReopen`" and named no test work.
  Carried by Red team.
- **W6 — CONFIRMED on the numbers.** Comparable hand-built AppKit windows in
  this app: `SettingsWindowController` 1012 lines, `RecordingHUDPanel` 412,
  `EmptyDocumentWindow` 135 for a drop target and one button. Welcome's
  feature set (guidance, permission rows, recents list, two buttons, drop
  target) lands well past 135, and `ci.yml` runs no `SnittAppTests`, so PR B
  as scoped bundles a large new window, a launch-behaviour swap, a `File ▸ New`
  rewiring and a deletion, with build-only coverage in CI. Carried by the
  Pragmatist.

### Rejected

- **W7 — Product/UX asked to narrow decision 3** so a Dock click with
  non-empty recents still reopens the most recent directly. `DockReopen.swift`
  does do that today (`:28-36`), which is accurate. **Revisit gate not
  satisfied:** the product owner chose this knowing the cost — the option
  they picked said reopening becomes "one visible click instead of an
  invisible automatic action" and that it "replaces DockReopen's no-recents
  notification too". No new fact, same tradeoff. Recorded, not reopened, and
  surfaced to them in one line so they can overrule.
- **W8 — Pragmatist proposed shipping a one-line swap now**
  (`main.swift:228` → `EmptyDocumentWindow.show`) to kill the modal panel
  immediately. **Rejected on the evidence.** `LaunchOpenPrompt`'s own doc
  comment says offering Open "is the answer to 'I launched this to work on a
  recording'", and `EmptyDocumentWindow` is a drop-a-video importer. The swap
  trades one wrong default for a different wrong default, on a type decision 1
  deletes. The modal panel is not urgent enough to justify an interim
  regression for the open-an-existing-recording case.

## Decision log

- **D1 — the getting-started hotkey tip reads `HotkeySettings`, not
  `KeyboardShortcutRegistry`, and lives in `.gettingStarted`.** `Decided`,
  auto-applied: a verified correction of a wrong citation, and hardcoding a
  rebindable value is not a tradeoff. *Given:* W1, W2.
- **D2 — `WelcomeContent` stays non-isolated; every `@MainActor` hop lives in
  `WelcomeWindow`, which passes plain data in.** `Decided`, auto-applied.
  *Given:* W2, and `LaunchOpenPrompt`'s own lack of isolation as the pattern.
- **D3 — PR C rewrites `DockReopenTests.swift` in the same commit that
  deletes `DockReopen.swift`.** `Decided`, auto-applied: without it the test
  target does not compile. *Given:* W5.
- **D4 — the Dock path must run a §4.11 suppression check before showing
  Welcome.** `Decided` that SOME check is required (not a tradeoff; it is a
  correctness hole). WHICH behaviour it takes goes to the product owner.
  *Given:* W4. `shape: a new entry point that skips an existing suppression
  rule`.
- **D5 — the Dock path reuses `LaunchOpenPrompt`'s decision.** `Decided` by the
  product owner. Recording or agent-launched means do nothing; otherwise show
  Welcome. One suppression rule serving both front doors, and its four cases
  are already reasoned and tested. *Given:* W4.
- **D6 — observe `NSApplication.didBecomeActiveNotification` and re-run the
  permission rows.** `Decided` by the product owner. Picks up a Microphone
  grant live (G9: AVFoundation reports it immediately). The relaunch wording
  is still required in the resting state for Screen Recording and Input
  Monitoring, because no refresh can make those two reflect a grant before
  the next process launch — the refresh and the wording are complements, not
  alternatives. Carries the app's FIRST observer lifecycle: registered in
  `init`, token held as a stored property, removed in `windowWillClose` (the
  hook `EmptyDocumentWindow` already uses for its own teardown). The handler
  re-runs `permissionRows()` only, never a full window rebuild. *Given:* W3.
- **D7 — four PRs: A, B1, B2, C.** `Decided` by the product owner. B1 builds
  the window and shows it from `File ▸ New` only, leaving the Open panel on
  bare launch; B2 swaps bare launch and deletes `EmptyDocumentWindow`. The
  window gets exercised before it becomes the only front door, and the
  derivation logic is reviewable apart from the AppKit assembly. Accepted
  cost: a brief interim state with two entry points. *Given:* W6.

## Final plan

### PR A — `WelcomeContent` (pure, no UI, no behaviour change)

`Sources/SnittApp/WelcomeContent.swift`, non-isolated (D2), in the shape
`LaunchOpenPrompt` established:

- `guidance(hasRecordings: Bool) -> Guidance` → `.gettingStarted` /
  `.quickTips([Tip])`, derived from the filtered recents list so no flag can
  get stuck (settled decision 2).
- `recents(from: [URL], fileManager: FileManager) -> [Entry]` —
  existence-filtered (G5 is new work), capped, most-recent-first.
- `permissionRows(screenGranted:micGranted:inputGranted:micEnabled:inputLoggingEnabled:)
  -> [PermissionRow]` — Screen Recording always; Microphone only when
  `MicrophoneSettings` is on; Input Monitoring only when
  `EventLoggingSettings` is on (G12). Each row carries the service, whether it
  is granted, and `requiresRelaunch` (G9: true for screen recording and input
  monitoring, false for microphone).
- The getting-started hotkey line reads
  `HotkeySettings.load(defaults)[.record].displayString` (D1), never a
  hardcoded ⌥⌘5.

Tests: guidance both ways; recents filtering, ordering and cap; permission
rows for each enabled/granted combination; the hotkey line reflecting a
rebound combination. Mutants for the filter, the cap, the relaunch flag and
the row-relevance gates.

### PR B1 — `WelcomeWindow`, shown from `File ▸ New` only

`Sources/SnittApp/WelcomeWindow.swift`, `@MainActor`, thin. Guidance section,
permission rows each with "Open Settings…" via
`PermissionOnboarding.settingsURL(for:)` (G11), recents list, `Open…` and
`Import Video…`, a drop target accepting `.snitt` and `ImportableMedia`
video, single-instance, self-closing when a document opens from it.

**Reads status only; never calls `ensureGranted` (G8). Never enumerates
windows (G10).** Observer per D6. Carries over the traps
`EmptyDocumentWindow` documents: `isReleasedWhenClosed = false`, the static
registry, `windowWillClose` teardown, and the drop view ordered above the
controls so it catches drags while declining clicks.

Bare launch still shows the Open panel at this point.

### PR B2 — bare launch swaps to Welcome; `EmptyDocumentWindow` deleted

`LaunchOpenPrompt.decide` keeps all four suppressions (G2); `.prompt` is
renamed `.welcome` and its doc comment rewritten rather than left arguing for
a panel. `offerToOpenADocumentIfLaunchedBare` shows Welcome.
`EmptyDocumentWindow` and its tests are deleted or rehomed (I1), and
`File ▸ New` points at Welcome.

### PR C — the Dock path

`applicationShouldHandleReopen` runs `LaunchOpenPrompt`'s decision (D5) and
shows Welcome when nothing suppresses it. `DockReopen.swift` is deleted and
`Tests/SnittAppTests/DockReopenTests.swift` is rewritten in the SAME commit
(D3) — `DockReopenTests` calls `DockReopen.handle` directly, so deletion is a
compile break, and `AppDelegateReopenTests` asserts the reopen-most-recent
behaviour being replaced.

### Cross-cutting

Every PR body quotes the doc comment it upholds or reverses, per
`.github/pull_request_template.md`. Full local `swift test` on each, since CI
runs neither `SnittAppTests` nor `SnittExportTests`. `Scripts/make-app.sh`
plus a hands-on launch is required before any of these is done, and for this
feature that is unusually load-bearing: a welcome screen is almost entirely
appearance and first-run feel, which no test here can report.

## Termination

**Condition 1, converged**, one pass. Every Important item is `Decided`; the
one whole-approach alternative (W8) was refuted on evidence rather than
parked; the conformance walk was clean (fresh ledger). Budget used: 4 persona
sub-agents, 0 cross-exam rounds.

Verdict: **Proceed.** No pivot, no kill.

## Implementation (2026-10-31)

Design iterated as a Design-type artifact before any Swift was written:
https://claude.ai/artifact/1NsLDztKbjc1EcVRDC26Cx — 23 revisions, four
artboards (first launch and returning, each in both appearances). Cheaper to
argue with than AppKit, and it caught several things the plan had wrong.

| PR | Branch | Gate |
|----|--------|------|
| #244 `WelcomeContent`, pure decisions | `feat/welcome-content` | 2358/2358, 10/10 mutants |
| #245 `WelcomeWindow` + `MascotView` | `feat/welcome-window` | 2394/2394, 22/22 mutants |
| (pending) front door + Dock path | `feat/welcome-is-the-front-door` | handed off |

#244 and #245 are a registered `gh stack` (#246), since #245 consumes #244.

### What the design pass changed about the plan

- **The primary action became Record, not Open.** Every empty-state source
  agrees on one prominent CTA, and a zero state should offer what the app is
  FOR. On first launch there is nothing to open anyway. `RecordingCoordinator`
  already serves the hotkey and the status item, so the button was cheap.
- **Copy caught three times.** "Snitt reads these, never asks for them" was
  simply false (`startRecording` ensures access; the Settings toggles run the
  ladder). "One window, not your whole screen" would have become false the day
  full-screen recording ships. And the tip slot was selling a feature to
  someone who had already installed the app, rather than teaching a move.
- **The mascot does not follow the appearance.** Three light-mode faces were
  rejected before the cause became clear: the EYE was a saturated amber blob,
  which reads as an animal iris on a pale frame. Fixed structurally by moving
  the colour onto the frame and giving the eyes a white sclera, not by a fourth
  colour guess.
- **The poke was too sad.** A 2.8s sulk with a tear that dripped twice made the
  product owner feel bad for clicking it. Now an 850ms flinch that grins
  itself off. Recorded in code comments so nobody reinstates it.

### Delegation, and what it cost

Three subagents (Sonnet) worked from written specs: the window, the mascot,
and the wiring. Specs carried the hard constraints explicitly (read permission
status only, never enumerate windows, no underlined links, no keycap chips)
and the REJECTED designs, because a smaller model will otherwise helpfully
reinstate them.

Both parallel agents were forbidden the full test gate and given
`--filter` only. Concurrent runs of this repo's AVFoundation-heavy targets
segfaulted the harness earlier the same day; the gate runs centrally and
serialised. `shape: a shared resource that fails silently under concurrency`.

Four corrections were needed on review of the two parallel agents, three of
which passed every test the agents wrote:

1. The record button was wired to `statusItem.onClick`, which is §5.3's KILL
   SWITCH. It worked only because that closure also calls `handleHotkey`, and
   it is an optional, so with no status item it silently did nothing.
2. The mascot's tracking area covered only its own 150x115 bounds, so the eyes
   followed for the last inch. Keeping it alongside the window's monitor would
   have been a visible bug: `mouseExited` fires on leaving the FACE, snapping
   the eyes front whenever the pointer moved off it but stayed in the window.
3. A local `.mouseMoved` monitor was not scoped to its own window, so an open
   editor's pointer movement drove the mascot in the wrong coordinate space.
4. The mascot's colourway was set once at build time, leaving a pale face on a
   dark pane after a system appearance switch.

**Two defects in my own specs, both caught by the agents:** the keenness ramp
was described backwards (the face would have been keenest when the pointer was
furthest from the button), and I asserted `NSButton.representedObject` exists
when only `NSCell` has it. Worth recording: the specs were reviewed by the
implementers, which is a benefit of writing them down rather than holding them
in one head.

### Still outstanding

The hands-on pass on all of it: `Scripts/make-app.sh`, relaunch, and actually
looking at the window. For a feature that is mostly appearance and animation
that is most of the point, and no test in any of these PRs can report on it.
