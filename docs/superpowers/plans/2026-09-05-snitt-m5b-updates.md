# M5b — Updates and Notarization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Snitt can be shipped by direct download — one version number, an embedded updater, a notarization script the maintainer can run, and an appcast generated from GitHub Releases.

**Architecture:** Version becomes one value read from the bundle rather than three literals. Sparkle is embedded by `make-app.sh` and signed inside-out. Everything decidable lives in Swift and is tested; the shell scripts stay thin and validate their inputs loudly, because they run rarely and fail at the worst moment.

**Tech Stack:** Swift 6, Sparkle 2.6+, `codesign`, `notarytool`, `stapler`, GitHub Releases.

**Spec:** `docs/superpowers/specs/2026-09-02-snitt-design.md` — §13 (M5), §4.3 (direct download first, Mac App Store later), §5 (privacy), §12 (diagnostics).

**Spikes:** `docs/superpowers/spikes/S9-sparkle-feasibility.md` — read it; it establishes that Sparkle works here and names what it did **not** settle.

**Decisions taken by the maintainer, encoded here:**
- Notarization is **scripted, not automated**: the scripts read credentials from the environment or a keychain profile and the maintainer runs them. **No secret enters the repository.**
- Updates are hosted on **GitHub Releases**, with the appcast generated from tagged releases.

## Global Constraints

- Swift 6, strict concurrency, **zero warnings from `Sources/`** under `swift build -Xswiftc -strict-concurrency=complete`. Verify from a clean build.
- macOS 15 minimum (§4.6).
- `SnittDocument` imports only Foundation. `SnittAutomation` → `SnittDocument` only. **`snitt-cli` and `snitt-mcp` must not link Sparkle** — it belongs to the app alone (§4.9). Verify with `otool -L`.
- **Baseline: 452 tests** at `9ba8ad6` from a full unfiltered run on a clean build.
- **Never block a thread from an async context.**
- Every test names a plausible wrong implementation and is verified to fail against it.

## Verification traps — every one has bitten this project

- **`swift test` exits 0 when the test bundle segfaults.** The crash is one inline `error: … signal code 11` line and the run has **no summary line**. Verify with `swift test 2>&1 | grep -E "Test run with|signal code|error:"` and **treat a missing summary as failure**.
- Piping to `grep` returns grep's exit status, so exit codes prove nothing.
- **When mutating: assert the target string was found before writing, and grep the mutated file before running.** A mutation that does not fail is as likely to be a bad mutation as a bad test.
- **A test that re-implements the safe behaviour inside its own body proves nothing about production.** M5a shipped a privacy test that logged the safe path itself, and it passed while a live leak was reproducible end to end. **Drive production code.**
- `timeout` does not exist on macOS. Do not reach for it in scripts.

## Spike results — measured, do not re-derive

1. Sparkle resolves, builds and links under SwiftPM with no Xcode project; SPM copies `Sparkle.framework` into the build directory.
2. The linked binary runs and instantiates `SPUUpdater`.
3. The rpath SPM emits is **`@loader_path`**, so the framework must sit beside the executable — `Contents/MacOS/` needs no rpath surgery; `Contents/Frameworks/` needs `@executable_path/../Frameworks` added.
4. Sparkle 2's XPC services are for **sandboxed** apps only. Snitt is not sandboxed, so the framework alone suffices.
5. **Not established by the spike:** that a signed bundle with an embedded framework passes Gatekeeper, or that the framework's signature survives `codesign --force` on the enclosing bundle. That is Task 2.

## File structure

| File | Responsibility |
|---|---|
| `Sources/SnittDocument/AppVersion.swift` (new) | One version value, read from the bundle. |
| `Scripts/make-app.sh` (modify) | Embed and sign `Sparkle.framework`; write Sparkle's Info.plist keys. |
| `Sources/SnittApp/UpdateSettings.swift` (new) | The opt-in for automatic update checks. |
| `Sources/SnittApp/UpdaterController.swift` (new) | Owns Sparkle's updater; honours the opt-in. |
| `Scripts/notarize.sh` (new) | Submit, staple, verify. Credentials from the environment. |
| `Scripts/make-appcast.sh` (new) | Generate an appcast entry from a release archive. |

---

### Task 1: One version, not three

**Files:**
- Create: `Sources/SnittDocument/AppVersion.swift`
- Modify: `Sources/SnittApp/AutomationHost.swift`, `Sources/SnittApp/DiagnosticsBundle.swift`, `Scripts/make-app.sh`
- Test: `Tests/SnittDocumentTests/AppVersionTests.swift`

**Interfaces:**
- Produces: `public enum AppVersion { public static var current: String { get } }` — reads `CFBundleShortVersionString`, falling back to a compiled-in constant when there is no bundle (tests, the CLI).

**Why this is first.** The version currently exists in **three** places: `SnittDocument.version`, a hardcoded `"0.1.0"` at `AutomationHost.swift:267`, and another literal in `make-app.sh`'s Info.plist.

Sparkle decides whether an update applies by comparing the appcast against **`CFBundleShortVersionString`**. If the app *reports* one version over the automation socket and *is* another in its plist, then `snitt --version` disagrees with what the updater sees — and the resulting bug looks like "updates sometimes don't appear", which is close to undiagnosable. §10 already makes version skew a first-class concern for the CLI; this is the same hazard one layer down.

**The fallback matters.** `Bundle.main` has no `CFBundleShortVersionString` when running under `swift test` or as `snitt-cli`. Returning `nil` or an empty string there would put an empty version into a diagnostics bundle. Fall back to a constant, and **keep the constant and the plist in sync from one source** — `make-app.sh` should read the constant rather than repeating it.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("A version is always reported, even with no bundle")
func versionIsNeverEmpty() {
    // Under `swift test` there is no CFBundleShortVersionString. An empty
    // string here would reach `snitt --version` and every diagnostics
    // bundle, where it reads as "unknown build" to a support engineer.
    #expect(!AppVersion.current.isEmpty)
}

@Test("The version looks like a version")
func versionIsWellFormed() {
    // Sparkle compares this against the appcast. A value that is not
    // dotted-numeric makes every comparison meaningless, and the symptom is
    // "updates never appear" rather than an error.
    let parts = AppVersion.current.split(separator: ".")
    #expect(parts.count >= 2)
    #expect(parts.allSatisfy { $0.allSatisfy(\.isNumber) })
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter AppVersion`
Expected: FAIL — `cannot find 'AppVersion' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// The app's version, in one place.
///
/// It lived in three: `SnittDocument.version`, a literal in
/// `AutomationHost`, and another in `make-app.sh`'s Info.plist. Sparkle
/// decides whether an update applies by comparing the appcast against
/// `CFBundleShortVersionString`, so an app that REPORTS one version and IS
/// another produces "updates sometimes don't appear" — a symptom with no
/// error attached to it. §10 already treats version skew as first-class for
/// the CLI; this is the same hazard one layer down.
public enum AppVersion {
    /// The value baked into the binary, and the single source
    /// `Scripts/make-app.sh` reads when writing `CFBundleShortVersionString`.
    /// Bump this and the plist follows; there is nowhere else to edit.
    public static let fallback = "0.1.0"

    public static var current: String {
        // No bundle under `swift test` or in `snitt-cli`. An empty string
        // here would reach a diagnostics bundle as "unknown build".
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? fallback
    }
}
```

Replace the literal at `AutomationHost.swift:267` and `SnittDocument.version`'s use in `DiagnosticsBundle` with `AppVersion.current`. Make `make-app.sh` extract `fallback` from the source rather than repeating the number — a `grep`/`sed` one-liner with a loud failure if it finds nothing.

- [ ] **Step 4: Run to verify it passes**

Full unfiltered run; expect 454. Then `./Scripts/make-app.sh` and confirm the built plist's version matches `AppVersion.fallback`.

- [ ] **Step 5: Verify the tests discriminate**

Make `current` return `""` and confirm `versionIsNeverEmpty` fails. Make it return `"dev"` and confirm `versionIsWellFormed` fails. Break `make-app.sh`'s extraction and confirm it exits loudly rather than writing an empty version.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests Scripts/make-app.sh
git commit -m "feat(updates): one version, read from the bundle"
```

---

### Task 2: Embed Sparkle, signed inside-out

**Files:**
- Modify: `Package.swift`, `Scripts/make-app.sh`
- Test: `Tests/SnittAppTests/BundleLayoutTests.swift` (new)

**Interfaces:**
- Produces: `Snitt.app` containing `Sparkle.framework`, both signed, with Sparkle's Info.plist keys present.

**Why this is its own task.** Spike S9 established that Sparkle links and runs, and explicitly did **not** establish that a signed bundle with an embedded framework holds together. **Signing order is the whole risk**: `codesign` must sign inner code *before* the enclosing bundle, and `make-app.sh` currently runs `codesign --force --sign … "$APP"` on the bundle alone. Signing the outer bundle after embedding an unsigned framework produces an app that launches from Finder and fails Gatekeeper on another machine — the worst possible time to discover it.

**Where the framework goes.** S9 measured the rpath as `@loader_path`, so `Contents/MacOS/Sparkle.framework` works with no rpath surgery. `Contents/Frameworks/` is conventional and needs `install_name_tool -add_rpath @executable_path/../Frameworks`. **Pick one, say why in a comment**, and make the test assert the chosen layout.

**Info.plist keys Sparkle needs:** `SUFeedURL` (the GitHub Releases appcast), `SUPublicEDKey` (the EdDSA public half), and `SUEnableAutomaticChecks` — **which must be `false`**. See Task 3 for why that is a privacy decision rather than a default.

- [ ] **Step 1: Write the failing test**

```swift
@Test("The built app embeds a signed Sparkle and declares its feed")
func builtAppEmbedsSparkle() throws {
    // Skips cleanly when the app has not been built, so `swift test` alone
    // never fails for want of a bundle — but when build/Snitt.app exists,
    // this is the only check that the embedding actually happened.
    let app = URL(fileURLWithPath: "build/Snitt.app")
    try #require(FileManager.default.fileExists(atPath: app.path),
                 "run ./Scripts/make-app.sh first")

    let framework = app.appending(path: "Contents/MacOS/Sparkle.framework")
    #expect(FileManager.default.fileExists(atPath: framework.path))

    // Signed INSIDE-OUT: an unsigned framework inside a signed bundle
    // launches locally and fails Gatekeeper elsewhere.
    #expect(codesignVerifies(framework))
    #expect(codesignVerifies(app))

    let plist = try plistOf(app)
    #expect(plist["SUFeedURL"] != nil)
    #expect(plist["SUEnableAutomaticChecks"] as? Bool == false)
}
```

`codesignVerifies` runs `codesign --verify --deep --strict` via `Process`; `plistOf` reads `Contents/Info.plist`.

- [ ] **Step 2: Run to verify it fails**

Run `./Scripts/make-app.sh` then `swift test --filter builtAppEmbedsSparkle`.
Expected: FAIL — no framework in the bundle.

- [ ] **Step 3: Implement**

Add Sparkle to `Package.swift` for the `SnittApp` target only. In `make-app.sh`, copy `Sparkle.framework` from `.build/debug/` into the chosen location, then sign **the framework first**, then the bundle. Write the three Sparkle keys into the plist.

- [ ] **Step 4: Run to verify it passes**

`./Scripts/make-app.sh`, then a full unfiltered run; expect 455. Then confirm the boundary held:

```bash
otool -L .build/debug/snitt-cli | grep -ci sparkle   # expect 0
otool -L .build/debug/snitt-mcp | grep -ci sparkle   # expect 0
```

- [ ] **Step 5: Verify the test discriminates**

Sign the bundle *before* the framework and confirm `codesignVerifies` fails on the app. Remove `SUEnableAutomaticChecks` and confirm the plist assertion fails. Restore.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Scripts/make-app.sh Tests
git commit -m "feat(updates): embed Sparkle and sign the bundle inside-out"
```

---

### Task 3: The updater, and an opt-in that means something

**Files:**
- Create: `Sources/SnittApp/UpdateSettings.swift`, `Sources/SnittApp/UpdaterController.swift`
- Modify: `Sources/SnittApp/StatusItemController.swift`
- Test: `Tests/SnittAppTests/UpdateSettingsTests.swift`, `Tests/SnittAppTests/UpdaterControllerTests.swift`

**Interfaces:**
- Produces:
```swift
public struct UpdateSettings: Sendable, Equatable {
    public var automaticChecksEnabled: Bool          // defaults FALSE
    public static func load(_ defaults: UserDefaults) -> UpdateSettings
    public func save(to defaults: UserDefaults)
}
@MainActor public final class UpdaterController {
    public init(settings: UpdateSettings)
    public var automaticChecksEnabled: Bool { get set }
    public func checkForUpdates()
}
```

**Why automatic checks default to false.** An update check is a network request that tells a server this machine is running Snitt, at a time the user did not choose. §5's framing is that Snitt is a recording tool people point at their own screens; it should not phone home before anyone asks it to. This mirrors `EventLoggingSettings`, whose comment names the same rule: **the default is the safety rule, not a preference.**

**System profiling must stay off.** Sparkle can attach a hardware and OS profile to update checks (`SUEnableSystemProfiling`). Leave it off and say so in a comment — it is exactly the kind of thing that gets switched on later "for analytics" without anyone re-reading §5.

**Follow `EventLoggingSettings` exactly** — same key-prefix convention, same `load`/`save` shape. A third settings shape in the same app is a small tax on every future reader.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("Automatic checks are off until someone turns them on")
func automaticChecksDefaultOff() {
    let defaults = ephemeralDefaults()
    // An update check tells a server this machine runs Snitt, at a moment
    // the user did not pick. Defaulting it on would be a decision made for
    // them (§5), and `EventLoggingSettings` sets the precedent.
    #expect(UpdateSettings.load(defaults).automaticChecksEnabled == false)
}

@Test("The choice survives a round trip")
func settingsRoundTrip() {
    let defaults = ephemeralDefaults()
    UpdateSettings(automaticChecksEnabled: true).save(to: defaults)
    #expect(UpdateSettings.load(defaults).automaticChecksEnabled)
}

@MainActor
@Test("The updater starts with automatic checks matching the setting")
func updaterHonoursTheSetting() {
    // The discriminating case: a controller that constructs Sparkle with its
    // own defaults ignores the user's choice entirely, and nothing else here
    // would notice.
    let off = UpdaterController(settings: UpdateSettings(automaticChecksEnabled: false))
    #expect(off.automaticChecksEnabled == false)
    let on = UpdaterController(settings: UpdateSettings(automaticChecksEnabled: true))
    #expect(on.automaticChecksEnabled)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "UpdateSettings|Updater"`
Expected: FAIL — types not found.

- [ ] **Step 3: Implement**

`UpdateSettings` mirroring `EventLoggingSettings`. `UpdaterController` wrapping `SPUStandardUpdaterController`, setting `automaticallyChecksForUpdates` from the setting at construction and on change. Add a "Check for Updates…" item to the status menu that calls `checkForUpdates()` — a manual check must work regardless of the automatic setting, since that is the user asking.

- [ ] **Step 4: Run to verify it passes**

Full unfiltered run; expect 458.

- [ ] **Step 5: Verify the tests discriminate**

Default `automaticChecksEnabled` to `true` and confirm `automaticChecksDefaultOff` fails. Ignore the passed settings in `UpdaterController.init` and confirm `updaterHonoursTheSetting` fails. Restore.

- [ ] **Step 6: Commit**

```bash
git add Sources/SnittApp Tests/SnittAppTests
git commit -m "feat(updates): an updater whose automatic checks are opt-in"
```

---

### Task 4: `notarize.sh`

**Files:**
- Create: `Scripts/notarize.sh`
- Test: `Tests/SnittAppTests/NotarizeScriptTests.swift` (new)

**Interfaces:**
- Produces: `Scripts/notarize.sh <path-to-app>`, reading credentials from `NOTARY_PROFILE` (a `notarytool` keychain profile) or `NOTARY_KEY`/`NOTARY_KEY_ID`/`NOTARY_ISSUER`.

**Why the maintainer runs it.** Notarization needs an Apple Developer account and credentials that must never enter this repository. The script's job is to be **runnable and loud**: validate every input before touching the network, and fail with a message naming what is missing.

**What is testable here, and what is not.** The submission cannot be tested without an account. **Argument and environment validation can** — run the script with no app path, a nonexistent path, and no credentials, and assert it exits non-zero with a message naming the problem. That is worth real tests: this script runs rarely, under release pressure, and a script that fails obscurely at that moment is worse than one that never existed.

**It must staple and then verify.** `notarytool submit --wait` succeeding does not mean the app is stapled; a stapled app is what works offline on someone else's machine. Run `xcrun stapler staple` and then `spctl --assess --type execute` and fail on either.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("Missing arguments fail loudly, before touching the network")
func notarizeRejectsMissingInput() throws {
    // This script runs rarely and under release pressure. A silent or
    // obscure failure at that moment is the whole cost.
    let noArgs = runScript([])
    #expect(noArgs.status != 0)
    #expect(noArgs.stderr.contains("usage"))

    let missingApp = runScript(["/nonexistent/Snitt.app"], env: ["NOTARY_PROFILE": "x"])
    #expect(missingApp.status != 0)
    #expect(missingApp.stderr.lowercased().contains("no such"))
}

@Test("Missing credentials name what is missing")
func notarizeNamesMissingCredentials() throws {
    let app = try makeStubApp(); defer { try? FileManager.default.removeItem(at: app) }
    let result = runScript([app.path], env: [:])
    #expect(result.status != 0)
    // Discriminating against a script that just fails: the message has to
    // tell the maintainer WHICH variable to set, at 2am, on a release.
    #expect(result.stderr.contains("NOTARY_PROFILE"))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter Notarize`
Expected: FAIL — no such script.

- [ ] **Step 3: Implement**

`set -euo pipefail`. Validate the app path exists and is a bundle; validate credentials; `ditto -c -k --keepParent` to a zip; `xcrun notarytool submit --wait`; `xcrun stapler staple`; `spctl --assess --type execute -vv`. Echo each step so a failed run says where it stopped.

- [ ] **Step 4: Run to verify it passes**

Full unfiltered run; expect 460.

- [ ] **Step 5: Verify the tests discriminate**

Remove the credential check and confirm `notarizeNamesMissingCredentials` fails. Remove the usage message and confirm the first test fails. Restore.

- [ ] **Step 6: Commit**

```bash
git add Scripts/notarize.sh Tests
git commit -m "feat(release): a notarization script that fails loudly"
```

---

### Task 5: The appcast

**Files:**
- Create: `Scripts/make-appcast.sh`
- Test: `Tests/SnittAppTests/AppcastTests.swift` (new)

**Interfaces:**
- Produces: `Scripts/make-appcast.sh <version> <zip> <release-url>` → an appcast XML item on stdout.

**Why a script and not a hand-edited file.** The appcast is the contract between a shipped app and every future release. A hand-edited XML file drifts from what was actually uploaded, and the failure is silent: Sparkle simply never offers the update, or offers one whose signature does not verify.

**The EdDSA signature is the maintainer's.** `sign_update` (shipped with Sparkle) uses a private key that must stay off this machine's repo and out of CI logs. The script takes the signature as an argument or reads it from `SPARKLE_SIGNATURE`; it must **refuse to emit an item with an empty signature**, because an unsigned entry is one Sparkle will reject at install time — after the user has downloaded it and waited.

**GitHub Releases is the host** (the maintainer's decision), so the enclosure URL is the release asset URL. Take it as an argument rather than constructing it, so a re-tagged or renamed release cannot silently produce a 404.

- [ ] **Step 1: Write the failing tests**

```swift
@Test("An appcast item carries version, URL and signature")
func appcastItemIsComplete() {
    let out = runScript(["1.2.0", "/tmp/Snitt-1.2.0.zip", "https://example.test/S.zip"],
                        env: ["SPARKLE_SIGNATURE": "abc123"])
    #expect(out.status == 0)
    #expect(out.stdout.contains("sparkle:shortVersionString=\"1.2.0\""))
    #expect(out.stdout.contains("https://example.test/S.zip"))
    #expect(out.stdout.contains("abc123"))
}

@Test("An unsigned item is refused, not emitted")
func unsignedAppcastIsRefused() {
    // Sparkle rejects an unsigned update at INSTALL time — after the user
    // has downloaded it and waited. Failing here costs a release; failing
    // there costs the user's trust.
    let out = runScript(["1.2.0", "/tmp/S.zip", "https://example.test/S.zip"], env: [:])
    #expect(out.status != 0)
    #expect(out.stderr.contains("SPARKLE_SIGNATURE"))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter Appcast`
Expected: FAIL — no such script.

- [ ] **Step 3: Implement**

Emit one `<item>` with `sparkle:shortVersionString`, `sparkle:version`, the enclosure URL, length, and `sparkle:edSignature`. Refuse an empty signature.

- [ ] **Step 4: Run to verify it passes**

Full unfiltered run; expect 462.

- [ ] **Step 5: Verify the tests discriminate**

Allow an empty signature and confirm `unsignedAppcastIsRefused` fails. Restore.

- [ ] **Step 6: Commit**

```bash
git add Scripts/make-appcast.sh Tests
git commit -m "feat(release): generate appcast items, never unsigned"
```

---

## Self-review

**Spec coverage.** §13's M5 names notarization (Task 4), Sparkle (Tasks 2, 3), and diagnostics (shipped in M5a). §4.3's "direct download first" is what makes Sparkle the right mechanism rather than the Mac App Store's. §5's privacy framing drives the opt-in default in Task 3.

**Deliberately excluded:**
- **A CI release workflow.** The maintainer chose to run notarization by hand. A workflow can come later; encoding credentials into CI before anyone has run the script once would be inventing a process nobody has tested.
- **Opt-in crash reporting** (§12's third bullet). Still deferred, and still for the same reason: it needs a reporter, a server, and a privacy decision about what leaves the machine.
- **The Mac App Store variant** — §13 puts it in M8.

**Known gaps a reviewer should weigh rather than assume:**

- **Nothing here proves an update actually installs.** Every test checks structure — the framework is embedded, the plist has keys, the appcast has a signature. A real end-to-end update requires two signed builds, a served appcast, and a machine willing to install one. That is a manual step, and the DoD names it.
- **Task 2's test only runs when `build/Snitt.app` exists.** It `#require`s the bundle and skips otherwise, so a plain `swift test` never fails for want of it — but that also means CI without a build step silently covers nothing. Say so rather than assuming the green suite includes it.
- **The version fallback can drift from the plist** if someone edits `make-app.sh`'s extraction. Task 1 makes the script fail loudly instead, but the coupling is real and a reviewer should check the failure actually fires.
- **`SUPublicEDKey` has no value yet.** The plist key is absent entirely (not a placeholder string), and an absent key does **not** make Sparkle refuse updates: `SUHost.m`/`SUSignatures.m` reads that as "no key configured" and falls back to requiring the downloaded update be code-signed to match the installed app's identity. On our HTTPS feed with a code-signed build, that fallback is safe, but it means EdDSA update-signature verification is not actually happening client-side yet — `make-appcast.sh` still refuses to emit an unsigned item, but nothing on the receiving end checks that signature. Before the first real release, run Sparkle's `generate_keys` once and paste the public half into `SUPublicEDKey`; see `docs/superpowers/notes/release-runbook.md`.

**Type consistency.** `AppVersion.current` in Tasks 1, 2. `UpdateSettings` in Task 3. Script argument shapes in Tasks 4, 5 match their tests.

## Manual verification (Definition of Done)

Automated tests cover structure, not the update itself. These need a person, and most need an Apple Developer account:

1. `./Scripts/make-app.sh`, then `codesign --verify --deep --strict build/Snitt.app` — passes.
2. `./Scripts/notarize.sh build/Snitt.app` with credentials set — submits and **staples**. Then, **only after stapling**, `ditto -c -k --keepParent build/Snitt.app Snitt-0.1.0.zip` to produce the distributable archive — never distribute the temp zip `notarize.sh` submitted and deleted, which predates the staple. `spctl --assess` against the stapled `.app` passes. See `docs/superpowers/notes/release-runbook.md` for the full ordering and why it matters.
3. Copy the stapled, re-zipped app to another Mac and open it. It should launch **without** a Gatekeeper warning. This is the only check that notarization actually worked.
4. Generate a keypair with Sparkle's `generate_keys`, put the public half in the plist, and keep the private half out of the repo.
5. Build 0.1.0, notarize + staple + **re-zip the stapled bundle** (step 2's ordering), publish that zip plus a `make-appcast.sh`-generated `appcast.xml` to GitHub Releases, and confirm 0.1.0 offers and installs 0.1.1.
6. Confirm a fresh install does **not** check for updates until the setting is enabled.
