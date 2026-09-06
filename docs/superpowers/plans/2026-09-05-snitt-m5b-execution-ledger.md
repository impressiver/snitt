# SDD ledger — plan: docs/superpowers/plans/2026-09-05-snitt-m5b-updates.md

MAINTAINER DECISIONS, taken before planning and encoded in the plan:
 - Notarization is SCRIPTED, not automated: scripts read credentials from the environment or a notarytool keychain profile and the maintainer runs them. NOTHING SECRET ENTERS THE REPO.
 - Updates are hosted on GITHUB RELEASES, with the appcast generated from tagged releases.

PRE-FLIGHT CONFLICT SCAN:

| Tasks | Shared surface | Produces | Consumes | Finding |
|---|---|---|---|---|
| 1 -> 2 | AppVersion.fallback | Task 1 | make-app.sh reads it to write CFBundleShortVersionString | CONFLICT: source-to-script coupling, ruling R1. |
| 2 -> 3 | Sparkle in Package.swift | Task 2 adds it to SnittApp only | Task 3 imports it | Clean, but see R2 on the frontends. |
| 2 -> 3 | SUEnableAutomaticChecks in plist | Task 2 writes false | Task 3's setting governs at runtime | CONFLICT: two sources for one behaviour, ruling R3. |
| 4, 5 | shell scripts tested from Swift | - | - | Clean; validation is testable, submission is not. |
| 1 -> all | SnittDocument.version | replaced by AppVersion | PackageSmokeTests asserts it | Task 1 must update that test rather than leave a stale constant. |

RULING R1 (version coupling): Task 1 makes make-app.sh EXTRACT AppVersion.fallback from the source instead of repeating the number. That coupling is real and brittle -- a sed/grep against Swift source -- so the script must FAIL LOUDLY when extraction finds nothing rather than writing an empty CFBundleShortVersionString. An empty version is worse than a wrong one: Sparkle compares against it, and the symptom is "updates never appear" with no error. Cost if wrong: a release ships with a version the updater cannot compare.
RULING R2 (Sparkle must not reach the frontends): Sparkle goes in Package.swift for the SnittApp target ONLY. snitt-cli and snitt-mcp must not link it -- §4.9's thin client, verified with otool rather than the import scan, which has been defeated three times in this project. Cost if wrong: an updater framework linked into a CLI an agent invokes.
RULING R3 (two sources for automatic checks): the plist's SUEnableAutomaticChecks and UpdateSettings.automaticChecksEnabled both govern the same behaviour. The PLIST IS THE COLD-START DEFAULT (false, so a fresh install never phones home before anyone asks) and the SETTING IS THE USER'S CHOICE, applied at construction and on change. Task 3's updaterHonoursTheSetting is what pins the second half. Cost if wrong: the setting reads as enabled while Sparkle never checks, or worse, a fresh install checks before consent.

FINDING while surveying, which sharpens Task 1's rationale: SnittDocument.version is a bare constant in an otherwise-empty enum (SnittBundle.swift:4), used by exactly two callers -- DiagnosticsBundle as `appVersion`, and a package smoke test. So diagnostics currently reports a MODULE CONSTANT as the app version, matching make-app.sh's plist only by coincidence. Three literals, one of which is not even nominally a version of the app.
SPIKE S9 answered M5b's load-bearing question before the plan: Sparkle resolves, builds and links under SwiftPM with no Xcode project, the binary runs and instantiates SPUUpdater, and the rpath is @loader_path so the framework can sit beside the executable with no rpath surgery. Sparkle 2's XPC services are for SANDBOXED apps only and Snitt is not sandboxed.
S9 explicitly did NOT establish that a signed bundle with an embedded framework passes Gatekeeper, or that the framework's signature survives codesign --force on the enclosing bundle. Signing order is Task 2's risk and Task 2's test. Recorded so nobody reads S9 as broader than it is -- I over-generalised S7's zero-retry result in M4b and want that noted rather than repeated.
Baseline 452 at 9ba8ad6. Branch feat/m5-packaging (M5a is PR #10, stacked on #9 on #8; all three unmerged).

Task 1: complete c965471, 454 tests, 3 runs. AppVersion.current/fallback created; SnittDocument.version REMOVED rather than left alive to keep a test green; AutomationHost:267 and DiagnosticsBundle:67 repointed; make-app.sh extracts fallback via sed with a loud exit 1 when extraction finds nothing. Verified the built plist matches AppVersion.fallback -- the coupling this task exists to create, which no test can see.
All three prescribed mutations verified: empty fallback, "dev" fallback, and a broken script extraction each failed their targeted check.
Implementer's own flagged concern, honest and worth a decision at review: the surviving PackageSmokeTests assertion is now a STRICT SUBSET of AppVersionTests.versionIsNeverEmpty rather than an independent check. Not wrong, but it now costs a run and guards nothing the other does not -- a reviewer should say whether it earns its place as a link/build smoke test or should go.

## Task 2: Sparkle embedding and signing — implemented, awaiting review
- Commit: 9e92c3b — 457 tests (454 baseline + 3), run 3x, all `Test run with 457 tests ... passed`
- Layout: Sparkle.framework at Contents/MacOS/ (matches SPM's @loader_path rpath, no install_name_tool)
- Sparkle 2.9.6 in Package.swift for SnittApp only; otool -L shows 0 hits in snitt-cli/snitt-mcp (R2 satisfied)
- Plist: SUFeedURL (GitHub Releases atom), SUEnableAutomaticChecks=false (R3), SUPublicEDKey empty placeholder
- Implementer finding (SUPublicEDKey empty): verified against Sparkle 2.9.6 source — neither "refuse all"
  nor "accept anything"; for .app updates it falls back to requiring a matching Developer ID identity
  between old and new bundle. Dev builds are ad-hoc, so no valid path exists and updates are rejected.
  Safe now, NOT a substitute for a real key before shipping.
- Implementer finding (self-reported, honest): `frameworkAndAppAreBothSigned` does NOT discriminate
  signing order. Verified by direct mutation — reordering the two codesign calls does not fail it,
  because SPM's vendored Sparkle.framework arrives pre-signed ad-hoc, so codesign treats it as
  independently valid either way. The test does catch framework-absent and signature-stripped.
  It does NOT catch "left at vendor ad-hoc, never re-signed with our identity" — which is precisely
  what Apple's notarization service rejects. This is the task's stated risk, still open.

### Task 2 review: changes required (2 Critical, 3 Important, 4 Minor) — fix round 1
Review: .superpowers/sdd/2026-09-05-snitt-m5b-updates/task-2-review.md
Reviewer confirmed independently: 457 tests, R2 holds, R3 holds, and implementer finding 2
(empty SUPublicEDKey rejects rather than accepts) is CORRECT — no security defect.

Rulings:
- R4: the skip path must actually skip. Reviewer proved `#require` RECORDS A FAILURE, and that the
  implementer's "confirmed it does not fail" check was vacuous because SwiftPM runs with cwd = package
  root, so build/Snitt.app was present. A fresh clone gets 3 hard failures. Cost if wrong: none — a
  genuinely-skipping test is strictly safer than one that fails on a machine that never built the app.
- R5: CFBundleVersion is required, and the missing test is the real finding. SUHost.validVersion needs
  it; without it SPUUpdater.checkIfConfiguredProperly bails with SUInvalidHostVersionError before Task 3's
  updater can start. The plist test asserted the three SU* keys and nothing asserted Sparkle could
  actually configure itself — the twenty-fourth instance of the adjacent-property class. The fix is the
  key AND an assertion that drives Sparkle's own validation.
- R6: the signing-identity test gets written NOW, not deferred. Reviewer showed `codesign -dvv` reports
  Signature=adhoc on the vendor copy and Authority=Snitt Development on a correctly re-signed one, so
  the existing self-signed dev cert discriminates today. This was a missing test, not a Developer ID
  blocker — the deferral was wrong.
- R7: --deep must go. It strips the hardened runtime flag (0x10002(adhoc,runtime) -> 0x0(none)) from
  Sparkle.framework, Updater.app and Autoupdate and drops nested entitlements. This diff INTRODUCED a
  notarization rejection inside the very task that exists to prevent one. Sign inside-out explicitly
  with --options runtime and --preserve-metadata=entitlements.
- R8: SUFeedURL points at the appcast Task 5 generates, not GitHub's releases.atom. Atom is not RSS;
  SUAppcast.m:89 parses /rss/channel/item and would find zero items forever. Carry a comment naming
  Task 5 as the producer, matching the SUPublicEDKey placeholder's convention.

### Task 2 fix round 1: 599016a — 461 tests (twice), awaiting scoped re-review
All of R4-R8 plus minors addressed. Hardened runtime flag now survives on every nested component.
New, discovered mid-fix and NOT previously flagged: enabling hardened runtime broke local launch,
because the self-signed dev identity has no real Team ID, so dyld's library validation treated app
and framework as mismatched despite the same identity. Worked around with
`com.apple.security.cs.disable-library-validation` on the app's entitlements. UNVALIDATED against
notarization; must be re-examined at Task 4 when a real Developer ID exists.
Two tests self-reported as non/partially-discriminating (see report). SUPublicEDKey now OMITTED
rather than empty-string, pending a real keypair.

### Task 2 re-review: changes required (narrow) — fix round 2
Re-review: .superpowers/sdd/2026-09-05-snitt-m5b-updates/task-2-rereview.md
All five rulings R4-R8 confirmed genuinely fixed, each verified by execution rather than by reading:
R4 skip proven by moving the bundle aside (6 real skip lines); R5's test drives SPUUpdater.start() and
fails with Sparkle's own Code=7 when CFBundleVersion is deleted; R6 discriminates a vendor-framework
swap; R7's runtime flag read back as 0x10000 on framework, Updater.app, Autoupdate and both .xpc;
R8 comment names Task 5's producer.
R5's test also settled round 1's open question BY EXECUTION: SUPublicEDKey = "" fails with Code=1,
so omitting the key (what the implementer did) is correct.

Rulings:
- R9: the disable-library-validation entitlement becomes conditional on the identity having no Team ID.
  The reviewer reproduced the dyld failure and confirmed it is inherent to teamless identities, not a
  masked signing bug, and that it does NOT block notarization — so the diagnosis was right. It still
  must not ship unconditionally: Snitt holds Screen Recording and Microphone TCC grants and embeds an
  updater that downloads and runs code, and the entitlement lets any validly-signed dylib load into
  that process. Keep hardened runtime everywhere. Cost if wrong: a dev-only launch failure, which is
  loud and local — the opposite of the failure shipping it unconditionally would buy.
- R10: add a test asserting a Developer ID build carries NO disable-library-validation. Nothing
  currently pins the app's entitlements at all, which is why this could be added mid-fix and reviewed
  only because the implementer volunteered it.
- R11: keep both self-reported "weak" tests, but for their real reasons, and fix the lie.
  frameworkAndAppAreBothSigned stays — it is the ONLY test catching seal integrity (nested code
  modified or invalid), which the identity test passes straight through. appBinaryLinksSparkleViaLoaderPath
  stays as a toolchain canary on the linker-emitted @loader_path, but its in-file comment claims it
  catches the location regression the implementer PROVED it cannot. A comment asserting a check that
  does not exist is the same defect as the Package.swift comment from round 1.
- R12: the summary line no longer proves packaging coverage — Swift Testing counts skips inside N, so
  `461 tests ... passed` reads identically with and without build/Snitt.app. Make the skip visible to
  anyone reading a CI log without reading every line.

### Task 2 fix round 2: 5792fb9 — 464 tests + 1 known issue (deliberate synthetic fixture), awaiting re-review
R9-R12 addressed. SNITT_REQUIRE_APP_BUNDLE=1 with the bundle absent flips the summary line to "failed",
verified in both states — R12's visibility gap closed via an opt-in strict mode rather than by trusting
a reader to notice a skip.
Open: appEntitlementsCarryNoWorkaroundLeakUnderARealTeamID cannot exercise its real-team branch without
a Developer ID; a synthetic test proves the logic instead. Re-confirm at the first notarized build.
Implementer corrected its own round-1 factual error unprompted (frameworkAndAppAreBothSigned passes,
not fails, on the vendor-swap mutation when the app is re-signed after).

### Task 2 re-review 2: changes required (1 real finding) — fix round 3
Re-review: .superpowers/sdd/2026-09-05-snitt-m5b-updates/task-2-rereview-2.md
R9 fixed, both directions verified by execution (teamless build launches with runtime flag intact;
real-Team-ID branch simulated on a scratchpad copy produces a bundle with NO entitlements that still
passes --verify --deep --strict). R11 fixed, comment now true — otool -l confirms identical
@loader_path between pre-packaging and packaged binaries. R12 fixed, reviewer verified both ways
against a `git archive HEAD` clone: unset -> 7 real skips; SNITT_REQUIRE_APP_BUNDLE=1 -> 7 hard
failures and a "failed" summary line.

Rulings:
- R13: the synthetic entitlement test gets replaced by the real proxy the reviewer demonstrated in six
  lines by hand — inject the team line into make-app.sh and assert against a REAL signature. As written
  it is a test of its own fixture: it checks that a helper finds a string in a literal the test itself
  just wrote, gated on a script answer another test already asserts, and never touches
  entitlementsXML(of:) or make-app.sh. The wrong implementation that matters — the entitlement applied
  unconditionally — is invisible on every machine that can run this suite. That is the twenty-fifth
  instance of the adjacent-property class, and this time it was introduced by the fix for a finding
  about an unguarded entitlement.
- R14: narrow the withKnownIssue scope to the intended failure only. Reviewer proved by mutation that
  `chmod -x` on the decision script makes Process.run() throw INSIDE the wrapper; the throw is recorded
  as the known issue and the test reports "passed with 1 known issue" while executing none of its
  intended logic. Compounding it, the summary line now permanently reads "with 1 known issue", so a
  second accidental one is invisible — the project's one trusted signal, degraded.
- R15 (minor): `line="${1:-$(cat)}"` fires on an EMPTY $1, so an empty TEAM_LINE (grep miss) makes the
  script read stdin — hang on a terminal, silent `no` under /dev/null. Not currently reachable. Use
  `${1-...}` plus an explicit empty check.

## Task 2: complete — 404260e, APPROVED
Re-review 3: .superpowers/sdd/2026-09-05-snitt-m5b-updates/task-2-rereview-3.md
464 tests in 8 suites passed, zero known issues, strict-concurrency clean.
R13 verified by the demanded mutation: making the entitlement unconditional (`if true; then`) in
sign-app-with-workaround.sh FAILS the test on the real re-signed bundle's entitlements; reverting
restores the pass. The test runs the real production script against a real copy with an injected
TeamIdentifier and reads back the actual signature — no fixture. This is exactly what its predecessor
was blind to.
R14 fixed without deleting the assertion: withKnownIssue is gone codebase-wide, count unchanged at 464
(one test replaced by one), assertNoWorkaroundLeak survives and is still called.
R15 fixed, all input shapes verified.
Structural split judged SOUND by mutation: replacing make-app.sh's call to the extracted script with a
bare codesign FAILS the teamless test. Both scripts are on the production path, pinned from both ends.

Parked minors (carried, not lost):
- N7: stale comment at Tests/SnittAppTests/BundleLayoutTests.swift:448 naming the deleted test.
  Folded into Task 3's dispatch.
- N8: if needs-teamless-workaround.sh cannot execute, sign-app-with-workaround.sh silently takes the
  else branch and make-app.sh exits 0 printing "Real Team ID (TeamIdentifier=not set)". Reproduced;
  the suite DOES catch it. Revisit at Task 4 with the real signing path.
- N9: SNITT_FAKE_TEAM_IDENTIFIER_LINE is an accepted production-script override of a security-relevant
  read. It exists so the test can produce a real signature without a Developer ID. Ruling: keep for now
  — it is what makes R13's test real rather than fixture-shaped — but Task 4 must decide whether it can
  be gated or removed once a genuine identity exists. Cost if wrong: an env var that persuades the
  signing script it has a team ID, sitting in shipped tooling.

Still needing a real Developer ID (not resolvable in-repo): actual notarization, the real-team launch
branch, and re-confirming the entitlement guard against a genuinely notarized build.

## Task 3: updater and opt-in setting — implemented, awaiting review
- Commit: afd6976 — 469 tests (464 baseline + 5), run twice, strict-concurrency clean
- UpdateSettings mirrors EventLoggingSettings; corrupt AND absent both read as off
- UpdaterController is @MainActor over SPUStandardUpdaterController; forwards the setting to Sparkle's
  own automaticallyChecksForUpdates rather than building a second scheduler. Construction never starts
  Sparkle — only AppDelegate.applicationDidFinishLaunching calls start() — so tests are side-effect-free.
- "Check for Updates..." menu item always available regardless of the automatic setting (asking IS
  the user choosing).
- New .updates DiagnosticCategory; failures logged domain/code/localizedDescription, explicit .public,
  no String(describing:) on the NSError.
- The opt-in default test drives a REAL SPUUpdater against the built bundle and observes Sparkle's own
  willSchedule/willNotSchedule delegate callbacks — mutation-verified by flipping the default. Not a
  boolean read-back.
- Implementer concern: the "turning it off cancels an already-pending check" half of R3 is verified by
  READING Sparkle 2.6's source (setter -> notification -> resetUpdateCycleAfterShortDelay ->
  cancelNextUpdateCycle), not by a live test — because exercising it live would fire a real background
  network check against the real com.impressiver.snitt preference domain on a fresh machine.
  Refusing to make a test that performs an unrequested network request is the right call under S5;
  the open question for review is whether a NON-network test of that path exists.

### Task 3 review: spec PASS with reservations, quality REVISE (4 Important) — fix round 1
Review: .superpowers/sdd/2026-09-05-snitt-m5b-updates/task-3-review.md
No Criticals. R3's primary clause IS genuinely enforced and genuinely tested. 469 verified independently.

PREMISE CORRECTION, carried forward and load-bearing: a missing SUPublicEDKey does NOT cause Sparkle to
reject updates. With an https feed on a code-signed bundle it falls through to code-signature-only
validation. Task 2's ledger entry and my report to the user both said "rejects" — that was WRONG in the
permissive direction. Task 5 MUST add a real EdDSA key; it is not optional hardening.

Rulings:
- R16: tests must not touch the real com.impressiver.snitt preference domain. Proven, not inferred —
  the reviewer's mutated run left SUEnableAutomaticChecks = 1 in the real domain. Use SUDefaultsDomain
  in a throwaway fixture .app; SUHost.initWithBundle: honours it ahead of the bundle id.
- R17: the disclosed gap is an AVAILABLE test, not a limitation. Reviewer built the fixture and ran it:
  ["willSchedule", "willNotSchedule"] in 4.2s, real domain untouched, NO network request. Sparkle's own
  delegate witnesses the cancellation. Write it. Same technique fixes R16.
- R18: no production path can change the setting. UpdateSettings.save and the automaticChecksEnabled
  setter have ZERO non-test callers, no menu toggle exists (unlike EventLoggingSettings), and the
  plist's SUEnableAutomaticChecks suppresses Sparkle's own permission prompt forever. Automatic checks
  can never be enabled by any route. Safe, but the opt-in is un-optable and R3's "off" clause governs
  nothing — a setting with no way to set it is not a setting. Cost if wrong: shipping a preference the
  user cannot reach.
- R19: the reported mutation is NOT reproducible on a fresh machine and would fire a real network check
  there. With SULastCheckTime absent Sparkle takes the "overdue -> run one now" branch; the test produced
  .willSchedule only because the real domain already held SULastCheckTime = 2026-09-05 22:21:35. The
  test passes here for a reason that does not exist on a clean install — the exact shape this project
  keeps getting caught by, one level up: not an adjacent property, but an adjacent MACHINE STATE.
- R20 (minor): the brief's Step 5 mutation does not hold — flipping init's default to true leaves
  automaticChecksDefaultOff passing, because it goes through load(). Test is still sound under two other
  verified mutations. Nothing spans load()-from-empty-defaults -> Sparkle scheduling; close that.
  Also: updaterHonoursTheSetting leaves ~/Library/Preferences/swiftpm-testing-helper.plist behind.
- R21 (minor, spec-level not implementer error): privacy grep of the diff is CLEAN, but Sparkle's own
  localizedDescription strings interpolate bundle paths, so .public on that field can emit a home
  directory. Log it at .private or redact; this is the third instance of the same class.

### Task 3 fix round 1: e2a6e30 — 470 tests, awaiting scoped re-review
Run 4x (2 pre-clean, 2 after rm -rf .build); `defaults read com.impressiver.snitt` byte-for-byte
unchanged before/after every run; full clean strict-concurrency rebuild, zero warnings.
Accepted design fact (disclosed): turningOffCancelsAPendingCheck exercises cancellation via a raw
SPUUpdater fixture rather than through UpdaterController, because SPUStandardUpdaterController can
only target Bundle.main. updaterHonoursTheSetting pins that UpdaterController forwards to the exact
property that test observes — complementary, per the implementer, not a gap. To be judged at re-review.

### Task 3 re-review: REVISE (1 Important, 1 Minor) — fix round 2
Re-review: .superpowers/sdd/2026-09-05-snitt-m5b-updates/task-3-rereview.md
R16-R21 ALL genuinely satisfied, each verified by execution: real domain byte-identical before/after a
full run; cancellation witnessed through Sparkle's own delegate with no network; menu item mirrors the
EventLoggingSettings four-part shape and both save(to:) and the setter now have non-test callers;
R19 verified empirically with SULastCheckTime ABSENT (the off-branch returns before lastUpdateCheckDate
is consulted, and a didFinishUpdateCycleFor probe showed no update cycle in either path);
R20's mutation re-run by the reviewer and it fails correctly; localizedDescription now .private.

Rulings:
- R22: the disclosed two-test composition DOES NOT hold, and the reviewer proved it by building the
  wrong implementation. An UpdaterController that caches automaticChecksEnabled in a private var and
  never forwards it to SPUUpdater passes updaterHonoursTheSetting (construct-and-read-back only) and is
  invisible to turningOffCancelsAPendingCheck (raw SPUUpdater, never touches the controller). Full suite
  under that mutant: `Test run with 470 tests in 8 suites passed`. The report's claim that
  updaterHonoursTheSetting "pins the forwarding" is true of the CONSTRUCTOR, not the SETTER — and the
  setter is the one production path R18 just added. The gap was created by the fix for R18 and hidden
  by a rationale that sounded like coverage. Five-line fix, already written and verified by the reviewer
  (passes real / fails mutant with `raw: Optional(0)`).
- R23 (minor): one empty com.snitt.test.fixture.<UUID>.plist leaks into ~/Library/Preferences per
  fixture (16 -> 18 across one run). removePersistentDomain empties the suite but leaves the file.

### Task 3 fix round 2: 544c3a0 — 470 tests, awaiting final scoped check
Run 4x (2 immediate, 2 after rm -rf .build); real domain byte-identical each time; full clean
strict-concurrency rebuild, zero warnings.
R22 closed and mutation-verified; the report's "complementary tests" claim was CORRECTED as wrong
rather than left standing.
R23 disclosed as bounded, not eliminated: cfprefsd can flush a fixture domain to disk AFTER the test
process exits, which nothing in-process can catch. The fix guarantees no unbounded growth via a
start-of-run sweep — verified 0 -> 1 -> 0 across the two final runs.

### Task 3 re-review 2: APPROVE with 1 Minor + 1 open uncertainty — fix round 3 (small)
Re-review: .superpowers/sdd/2026-09-05-snitt-m5b-updates/task-3-rereview-2.md
R22 PASS, verified by rebuilding the exact mutant: suite `failed after 40.611 seconds with 1 issue`,
restored source `470 ... passed`. Not decorative. The discrimination lives at
UpdaterControllerTests.swift:55 (the setter path); line 53 passes under the mutant because the
constructor already set it — redundant but harmless.
R23 reasoning correct and sweep sound against misfire: the `com.snitt.test.fixture.` prefix is unique
to this test file, nothing in Sources/ or the rest of Tests/ writes such a domain, and no Apple/user
domain shares it. Boundedness independently verified 2 -> 1 -> 1.
Report correction present and accurate — the retraction REPLACES the old claim rather than sitting
beside it.

Rulings:
- R24: close the sweep-vs-live-fixture race rather than parking it. sweepStaleFixtureFiles() runs inside
  make() and can delete the OTHER fixture test's live plist; both tests release the main actor at
  `await waitUntil`, so the interleaving is reachable, as is a second concurrent `swift test`. The
  reviewer saw no flake and believes cfprefsd keeps serving the domain from memory, so it did not raise
  it as a finding — but the harm mode if wrong is EXACTLY R19's overdue-check branch, i.e. a real
  unrequested network check, which is the single thing this task exists to prevent. A per-run prefix or
  mtime guard closes it cheaply. Cost if wrong: a rare flake that fires a network request on a
  developer's machine and is nearly unreproducible.
- R25 (minor): the report's recorded evidence does not match the described mutant — it quotes
  `2 issues` / `nil == true` / `nil == false` and the test comment quotes `(... -> false) == true`,
  but the described mutant produces 1 issue and `(... -> true) == false`. The quoted output belongs to
  a STRONGER mutant whose init also stopped forwarding. Conclusion unaffected, but a report whose
  evidence is from a different experiment than its claim is the defect this project has been correcting
  all milestone.

## Task 3: complete — 2efce2b
470 tests, run twice after rm -rf .build; real domain byte-identical before/after both runs;
clean-rebuild strict-concurrency, zero warnings.
R24 closed and demonstrated with a before/after probe. R25's evidence mismatch corrected with the
real re-run output.
Accepted known limit (disclosed, not asserted safe): two literally concurrent `swift test` PROCESSES
could still race on the fixture-preference sweep. Not reproduced, not fixed, stated as a boundary.
Ruling: accept. The same-process race is closed, and a second concurrent full test process is not a
normal workflow here; the honest boundary beats a speculative fix.

## Task 4: notarize.sh — implemented, awaiting review
- Commit: fe835de — 481 tests (470 baseline + 11), run 3x, each new test mutation-verified
- notarize.sh: distinct messages for missing/empty/nonexistent/non-bundle app paths; requires
  xcrun notarytool; refuses an unsigned bundle; NOTARY_PROFILE takes precedence over the
  NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER trio; zips/submits/staples/verifies, failing loudly at
  every stage. Tests assert refusal-to-proceed via a stubbed-PATH binary observing absence of the
  ditto/notarytool side effect — NOT merely that a message was printed.
- N8 FIXED and the root cause is worth keeping: `set -e` does NOT propagate a command substitution's
  failure through `[ "$(...)" = "yes" ]`, so the script failed open, took the "no workaround needed"
  branch and exited 0. Reproduced, fixed to fail loudly, re-verified by chmod -x on the decision script.
- N9 KEPT unchanged, with justification: notarize.sh performs no signing, so the real-Team-ID branch
  still cannot be exercised without a Developer ID this repo will never hold; the override remains the
  only non-fixture test of that branch. To be judged at review.
- AuthKey_*.p8 / *.p8 added to .gitignore.
Needs maintainer confirmation on the FIRST REAL notarized build (cannot be closed here):
  1. no disable-library-validation entitlement present, 2. real TeamIdentifier read correctly,
  3. clean launch on a machine that has never seen the app.

### Task 4 review: spec PASS, quality CONDITIONAL PASS (3 Important) — fix round 1
Review: .superpowers/sdd/2026-09-05-snitt-m5b-updates/task-4-review.md
Verified independently: 481 tests; secret scan of diff, tree, untracked AND ignored files CLEAN with
all fixture values visibly synthetic; N8 root cause confirmed exactly as reported (pre-fix + chmod -x
exits 0 printing "Real Team ID (TeamIdentifier=not set)", post-fix exits 1); no other fail-open command
substitutions in Scripts/; bash 3.2 + set -u safety of the empty-array idiom tested directly.
The implementer's central claim HOLDS: the mutation tests fail on the ABSENT MARKER, not the message.

Rulings:
- R26: cover the staple-then-verify half. Swallowing BOTH `stapler staple` and `spctl --assess`
  failures with `|| true` passes all 11 tests green. The script behaves correctly by hand, but the
  brief's own "fail on either" requirement has ZERO coverage — and it is the one failure mode that
  yields a distributable-LOOKING broken artifact, which is the whole point of notarizing. The existing
  fake-PATH harness covers it in ~10 lines.
- R27: add the N8 regression test. The fail-open fix shipped with none, and the same commit already
  demonstrates the harness that would cover it (copy Scripts/lib, chmod -x, assert non-zero) — that is
  how the reviewer verified it, with no repo mutation. Also exercise the elif/else unexpected-answer
  branch. A fix for a fail-open bug with no test is the shape that comes back.
- R28: KEEP SNITT_FAKE_TEAM_IDENTIFIER_LINE, but GATE it — refuse the override when the real signature
  carries a genuine TeamIdentifier. The implementer was right that a second opt-in flag reduces no risk,
  but it conflated that with this: the gate is not a flag, it is a refusal condition. Costs nothing
  today and makes the override incapable of masking a real Team ID at the maintainer's first
  Developer-ID run. Cost if wrong: an env var that can silently downgrade a real signing decision.
- R29 (minor): the ${1-} header rationale is INACCURATE — with an empty default word it is identical to
  ${1:-} and inert after the `$# -lt 1` guard. The real protection is the guard plus the -z check.
  Fix the comment; the risk is a future editor deleting the -z check believing the expansion covers it.
  (Same defect class as the Package.swift and BundleLayoutTests comments: a comment asserting a
  protection that is not there.)
- R30 (minor): probe spctl the way xcrun/notarytool are probed.
Carried uncertainty (reviewer flagged, version-dependent): notarytool submit --wait MAY exit 0 on an
Invalid submission. Contained — stapler then fails loudly, so a run never reads as success.

### Task 4 fix round 1: 2f570fd — 487 tests (470 + 17), awaiting scoped re-review
R26-R30 addressed. Every new/changed assertion re-verified against the reviewer's exact prescribed
wrong implementations: `|| true` on staple and on spctl SEPARATELY, exact pre-fix N8 reproduction,
R28 gate removal. Tree confirmed clean after each mutation.
Open, by design: the genuine-success paths of notarytool submit / stapler staple / spctl --assess
remain untestable without real credentials. R28's gate is verified against a FAKED codesign -dvv
reporting a synthetic genuine-shaped Team ID, not an actual Developer ID signature — the same
limitation N9 always carried, now bounded rather than removed.

## Task 4: complete — 2f570fd, APPROVED
Re-review: .superpowers/sdd/2026-09-05-snitt-m5b-updates/task-4-rereview.md — PASS, no new findings.
487 tests. R26 closed with BOTH mutations run separately: neither mutant is caught by the other's
test, so the pair genuinely partitions the two branches rather than one test covering both.
R27 closed by reverting the fix in place and reproducing the exact fail-open (exit 0,
"Real Team ID (TeamIdentifier=not set)"); the unexpected-answer test specifically catches loss of the
elif/else branch.
R28 closed, logic correct and the proxy judged FAIR: the faked codesign -dvv supplies only the INPUT,
while assertions are on script-authored behaviour (exit 1, the script's own refusal text, absence of
the fake line from acted-on output) — dependency stubbing, not asserting against a self-written
literal. Both halves of the gate condition discriminate: deleting it fails the R28 test, weakening it
to `[ -n "$REAL_TEAM_LINE" ]` alone fails the pre-existing Developer-ID-shaped test. No bypass without
already shadowing codesign on PATH.
Secret scan clean; only new credential-shaped values are REALTEAM123SYNTHETIC and FAKELINE999.
First real run must confirm: real codesign -dvv emits `^TeamIdentifier=` with the spelling the gate
compares against; the gate stays silent with the override unset; and the "library validation satisfied
without any extra entitlement" branch logs.

## Task 5: make-appcast.sh — implemented, awaiting review
- Commit: dbe7cd1 — 497 tests (487 baseline + 10), run twice identical
- Script refuses to emit ANY output when no signature is available (4th arg or SPARKLE_SIGNATURE,
  arg wins), checking BEFORE printing anything — verified no partial XML leaks to stdout on refusal.
- Tests use Sparkle's own tooling as the oracle: a real SPUUpdater fetches the generated feed from a
  local loopback HTTP server (hand-written minimal POSIX-socket server) and its
  didFinishLoading(appcast:) delegate is inspected for real SUAppcastItem fields, including reading
  sparkle:edSignature back out of propertiesDictionary["enclosure"].
- Cryptographic proof uses a THROWAWAY Ed25519 key via SecRandomCopyBytes, deliberately NOT Sparkle's
  generate_keys, which would touch the real login Keychain — correct call, an unacceptable test side
  effect. Used with `sign_update --verify` to confirm the signature is bound to the exact archive bytes
  and rejects tampering.
- Mutations verified then reverted: empty-signature bypass, hardcoded zero length, wrong-signature
  literal, dropped empty-version check.
- .gitignore updated with private-key export filename patterns.
Concerns disclosed: no full download-and-install cycle (manual DoD item by design); round-trip fixture
cleanup occasionally leaves one stray preference file under full-suite parallel contention — the same
previously-accepted class as SparkleFixture, not a new regression. defaults read com.impressiver.snitt
byte-for-byte unchanged across a full run.

### Task 5 review: spec PASS, quality PASS WITH FINDINGS (3 Important, 4 Minor) — fix round 1
Review: .superpowers/sdd/2026-09-05-snitt-m5b-updates/task-5-review.md
Key material CLEAN: no PEM/key content in diff, tree, untracked or ignored files; all signature
literals visibly synthetic; the ephemeral seed lives in a temp file deleted in defer; the login
keychain has NO Sparkle entry, so generate_keys demonstrably was not run. The reviewer judged that
choice right — generate_keys unconditionally touches the real login keychain.
5 mutants all killed: `if false` on the signature guard; partial-feed-then-exit-1 (killed by
stdout.isEmpty alone); dropped xmlns:sparkle (killed via Sparkle's own didAbortWithError); ONE
CHARACTER of signature corruption (sign_update --verify returned 1 vs 0 — the crypto binding is real
and the tamper assertion non-vacuous); enclosure URL drift (killed on Sparkle-parsed item.fileURL).
Assertions confirmed to be on SUAppcastItem fields, not test-written strings.
Task 4's fail-open pattern genuinely ABSENT, not merely claimed: stat is captured under `if !`, and
the signature guard tests a plain variable.

Rulings:
- R31: close the SUFeedURL <-> output gap. SUFeedURL is .../releases/latest/download/appcast.xml but
  make-appcast.sh writes to STDOUT and never names appcast.xml or that URL anywhere — not in the
  header, the usage, or a test. The two agree only if the maintainer remembers to type `> appcast.xml`.
  This is precisely the silent-no-op class the dispatch warned about: a feed at the wrong path produces
  no error anywhere, updates simply never appear. Pin the relationship in a test.
- R32: fix Scripts/make-app.sh:63-71 — it still labels SUFeedURL "PLACEHOLDER ... replace it with the
  real one when that task lands". Task 5 landed. A comment that misdescribes the shipping value is the
  FOURTH instance of that defect this milestone.
- R33: the disclosed cleanup concern is MISCHARACTERISED and is a real new finding.
  sweepStaleFixtureFiles() matches hasPrefix("com.snitt.test.fixture."); the new suite is
  com.snitt.test.appcast-fixture.*, which NOTHING sweeps. The accepted class was accepted precisely
  BECAUSE the sweep bounds it — so this round reaches a new, unbounded domain, which is R24's own
  stated failure mode. One-line fix. No privacy impact; com.impressiver.snitt verified untouched.
- R34 (minor): cross-check the <version> argument against the archive's own Info.plist — the zip is
  already opened to measure length, so the check is nearly free. Guards the exact mismatch class that
  makes Sparkle silently ignore an update.
- R35 (minor): refusal is total inside the script, but because it writes to stdout, a caller's
  `> appcast.xml` has ALREADY truncated the previous good feed before the refusal fires. Resolve
  together with R31.
- R36 (minor): LocalFixedResponseServer has an unsynchronised listenFD and closes it under a blocked
  accept() (fd-reuse race), and no partial-send loop. Binds loopback only, cannot hang, did not flake
  in three runs. Fix or state why not.
- R37 (minor): cleanUpRoundTripFixture's retry loop has no early exit and always sleeps 450ms,
  contradicting its own "without adding meaningful time" comment. Propagated from SparkleFixture —
  fix both.
Undetermined, carried: I3's actual accumulation rate (mechanism certain, rate unmeasured); whether
M3's fd race is reachable here. shellcheck is NOT installed, so no static pass was possible.

### Task 5 fix round 1: 34dac1e — 501 tests, awaiting scoped re-review
R31-R37 all addressed. Run twice identical; defaults read com.impressiver.snitt unchanged both runs.
Open, honestly characterized this time: under full parallel runs BOTH fixture prefixes can leave 1-2
stray files after a single run, dropping to 0-1 once the next run's sweep catches them — bounded by
the sweeps, not guaranteed zero under contention.
The implementer corrected its own prior mischaracterization of R33 (a genuinely unswept domain, not
"the same accepted class").

### Task 5 re-review: PASS with 1 NEW Important — fix round 2
Re-review: .superpowers/sdd/2026-09-05-snitt-m5b-updates/task-5-rereview.md
R31 resolved and mutation-verified IN BOTH DIRECTIONS — values flow from make-app.sh's real SUFeedURL
into the script invocation, not from a literal the test defines. Changing the plist path fails 3
assertions including the script-driven ones; changing only REQUIRED_OUTPUT_BASENAME fails 4. Not
self-referential. R32, R33 (measured empirically: 0 before, 2+1 after run 1, 1+1 after run 2 — the
prior run's files are demonstrably reclaimed), R35, R36 (genuinely fixed with NSLock + self-connect to
unblock accept() + semaphore before close, not merely justified), R37 all resolved.

Rulings:
- R38: fix the R34 version check — the fix for a minor introduced a release-blocking bug.
  `grep -m1 -E '(^|/)Contents/Info\.plist$'` matches the EMBEDDED
  Sparkle.framework/.../Downloader.xpc/Contents/Info.plist, and under this project's own
  `ditto -c -k --keepParent` (Scripts/notarize.sh:161) that entry is listed FIRST. Reproduced
  end-to-end: `error: <version> (0.1.0) does not match CFBundleShortVersionString found inside t2.zip
  (2.9.6)`, exit 1 — it would refuse EVERY real release. Anchor to
  '^[^/]+\.app/Contents/Info\.plist$' and add a nested-XPC fixture.
  archiveVersionMismatchIsRefused misses it because its fixture is a FLAT single-bundle zip: it tests
  "a mismatch is refused", not "the app's own version is read". Twenty-sixth instance of the
  adjacent-property class, and the first one introduced BY a fix rather than found in original work.
- R39: accept "bounded but non-zero" as the correct end state for fixture-preference cleanup, and do
  NOT ask for more. The reviewer reproduced the exact numbers; the residual is inherent — cfprefsd
  flushes after the owning test finishes, and the `< processStartTime` guard exists precisely so the
  sweep can never delete a fixture a parallel test still holds. Zeroing it needs a process-exit hook
  Swift Testing does not offer, for a 42-byte private throwaway.
Undetermined, carried: whether all real archives order entries as ditto did here (N1's mechanism does
not depend on it — `-m1` over an unanchored pattern is arbitrary either way); R36's race unreproduced.

### Task 5 fix round 2: 77f64fb — 502 tests, R38 fixed. Task 5 and M5b implementation COMPLETE.
Proceeding to whole-branch review of the full M5b range 433e4de..77f64fb.

## M5b whole-branch review: READY WITH CAVEATS — one fix wave
Review: .superpowers/sdd/2026-09-05-snitt-m5b-updates/whole-branch-review.md
No Criticals. Verified clean BY EXECUTION: the version chain end to end (R38's anchored pattern
confirmed against a real ditto archive where the nested XPC plists genuinely DO list first — 0.1.0
accepted, 9.9.9 refused); SUFeedURL <-> output basename in both directions; all five nested Sparkle
components at flags=0x10000(runtime) Authority=Snitt Development; the entitlement present ONLY under
the teamless identity; the R28 gate safe in all three directions; otool R2 (0/0/1); no fail-open
command substitutions remain anywhere; one new log site, correctly .private; secret scan clean.
502/502/502 across three runs, zero skips, zero known issues.
Note the reviewer applied the R19 trap TO ITS OWN CHECK: `defaults delete` was blocked, so rather than
comparing values it compared the MTIME of com.impressiver.snitt.plist — proving no write occurred
rather than a write that happened to produce an equal value.

Fix wave rulings:
- R40 (I1): delete UpdaterController.scheduleEvents and its two DelegateBridge scheduling callbacks —
  zero readers anywhere. Its doc comment claims it exists so a test can observe scheduling, but the
  only such test uses its own SchedulingSpy on a raw SPUUpdater and reuses only the enum type. R17's
  fix moved the observation and orphaned the hook. Dead code whose comment asserts a purpose it no
  longer serves is the fifth instance of that class this milestone.
- R41 (I2): write the release runbook joining notarize.sh (zips to a temp dir it DELETES) to
  make-appcast.sh (consumes a <zip> nothing produces). Nothing anywhere states the published archive
  must be zipped AFTER stapler staple; the plan's DoD omits it too. An unstapled archive works on the
  maintainer's online machine and FAILS on everyone else's — the worst possible failure signature.
- R42 (I3 + M1): correct every stale SUPublicEDKey claim (plan:456 "will refuse";
  DiagnosticCategory.swift:23 "once Task 5 adds a real key" — it did not), and state plainly that with
  the key absent Sparkle never reads sparkle:edSignature, so make-appcast.sh's "never unsigned"
  guarantee is UNENFORCEABLE client-side; integrity rests solely on TLS + Developer-ID signature
  matching. generate_keys + pasting the public key is a first-release REQUIREMENT.
- R43 (M2): sweep the third preference accumulator. UpdateSettingsTests adds snitt.updates.* at
  +2/run, 119 already present — while this milestone built two sweeps to bound a 1-2 file residual.
- R44 (M3): the one new test inheriting the process environment adopts the discipline the other three
  already use.
- R45 (M4): theSignatureIsCryptographicallyValid should skip, not hard-fail, when its tooling is absent.
- R46 (M5): make-app.sh hardcodes Sparkle's nested layout against a floating `from: "2.6.0"` — pin or
  derive it.
- M6 (leftover Sparkle keys in the real preference domain from Task 3's PRE-FIX runs): NOT a code
  defect and not the implementer's to clean — it is the user's machine state, caused by a bug already
  fixed. Report it to the user with the exact command; do not touch their defaults.

### M5b fix wave: bb164d0 — 503 tests across three runs, awaiting scoped re-review
R40-R46 all addressed. com.impressiver.snitt.plist mtime unchanged (the reviewer's own stronger method).
R40 kept the ScheduleEvent enum since SchedulingSpy still reuses it, and reverified the observing test
still discriminates — the deletion did not quietly weaken the suite.
R41 wrote docs/superpowers/notes/release-runbook.md and added the zip-after-staple requirement to the
plan's DoD. R42 fixed both known stale sites plus one more found by a branch-wide grep. R43's new sweep
test verified to fail when the sweep is disabled. R44 re-verified against its original mutant.
R45 now genuinely skips. R46 pinned Sparkle to exact: "2.9.6".
User machine state (NOT touched, correctly): cleanup command documented in the runbook's Housekeeping
section — defaults delete com.impressiver.snitt {SUEnableAutomaticChecks,SUHasLaunchedBefore,SULastCheckTime}

### Fix-wave re-review: READY WITH CAVEATS — one final one-line round
Re-review: .superpowers/sdd/2026-09-05-snitt-m5b-updates/fix-wave-rereview.md
503 tests twice on a clean tree, zero skips. R40 verified by mutation — the caching mutant still fails
at UpdaterControllerTests.swift:60 with byte-for-byte the failure R22 recorded, so the deletion took no
guard with it. R41(a) ordering correct and unambiguous. R43 swept, and the new test BACKDATES its
planted file to epoch 0 so it cannot pass on ambient state. R44/R45/R46 all re-verified by execution;
R46's five sign_nested calls cover exactly the three nested code objects present in 2.9.6.
Real domain: identical mtime AND SHA-1 across all runs. The documented cleanup command deletes the
three keys BY NAME — load-bearing, since the domain also holds five real user consent/recording
settings that a whole-domain delete would have destroyed.
Reviewer disclosed a flaw in its OWN method: its first R45 check used --filter "cryptographically",
which matched 0 tests in BOTH directions and would have read as a pass. Caught and redone.

Rulings:
- R47: fix the runbook's step 5. `sign_update <zip>` does NOT print a bare base64 signature — it emits
  `sparkle:edSignature="..." length="..."`; `-p` is the flag that prints the signature alone.
  make-appcast.sh does no shape validation, so following the runbook as written pastes a quote-escaped
  garbage attribute into a feed it emits without complaint. Masked today (no SUPublicEDKey means
  nothing reads the attribute) and it ARMS ITSELF precisely when the runbook's own "before the first
  real release" step adds the key. Also assign $SIGNATURE, which the document never does, and note
  sign_update is not on PATH.
- R48: kill the last stale claim — AppcastTests.swift:117 and make-appcast.sh:69 still carry the
  unqualified "Sparkle rejects an unsigned update at INSTALL time", and the new CURRENT STATE paragraph
  says "below" without covering it. Rationale comments only; no assertion is wrong.

## M5b COMPLETE — 90e910d, 505 tests
R47 and R48 closed. Runbook's sign_update step now uses -p with the correct path and assigns
$SIGNATURE; make-appcast.sh gained a targeted shape check (verified to fail-if-removed AND to accept a
genuine signature) so the latent garbage-attribute bug cannot arm itself when the key lands; the last
two stale "rejects unsigned at install time" claims and the broken cross-reference are fixed.
Real domain mtime unchanged. Ready for PR stacked on #10.
