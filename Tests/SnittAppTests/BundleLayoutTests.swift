import Testing
import Foundation
import Sparkle

// M5b Task 2: Snitt.app must embed Sparkle.framework signed INSIDE-OUT.
//
// `codesign` signs inner code before the enclosing bundle. Sign the outer
// bundle after copying in an unsigned (or wrongly-signed) framework and the
// app can launch fine from Finder on this machine but fail Gatekeeper or
// notarization on someone else's — a failure with no local reproduction.
// These tests hold make-app.sh to the order (framework first, then bundle),
// to the chosen embed location, to the framework carrying Snitt's own
// signing identity (not the vendor's ad-hoc one), and to Sparkle's own
// verdict that the resulting bundle is configured properly.
//
// All of them use a condition trait (`.enabled(if:)`), not `#require`, to
// skip when `build/Snitt.app` does not exist — `#require` records a hard
// failure on a false condition, it does not skip, so a fresh clone running
// `swift test` with no prior `./Scripts/make-app.sh` would otherwise get N
// hard failures here. Verified directly: moving the built bundle aside and
// re-running the suite shows these as skipped, not failed, and moving it
// back restores pass/fail as before.
//
// A CI run with no build step still exercises none of the assertions in
// this file — the condition trait means it exercises none of it silently.
// Swift Testing counts a skipped test inside the run's total and still
// reports the run "passed", so `Test run with N tests … passed` reads
// identically whether packaging was actually covered or not. R12: set
// SNITT_REQUIRE_APP_BUNDLE=1 (e.g. in CI, once it runs make-app.sh) to turn
// a missing bundle into a real, visible failure instead of a silent skip —
// unset (the default), local `swift test` behaves exactly as before.

private let app = URL(fileURLWithPath: "build/Snitt.app")
private let appIsBuilt = FileManager.default.fileExists(atPath: app.path)
private let requireAppBundle = ProcessInfo.processInfo.environment["SNITT_REQUIRE_APP_BUNDLE"] == "1"
private let appBundleSkipReason: Comment = "run ./Scripts/make-app.sh first (or set SNITT_REQUIRE_APP_BUNDLE=1 to fail instead of skip)"

// Contents/MacOS/, not Contents/Frameworks/: spike S9 measured the rpath SwiftPM
// emits as @loader_path, which resolves relative to the executable at
// Contents/MacOS/Snitt. Sparkle.framework living beside it there needs no
// install_name_tool rpath surgery. Contents/Frameworks/ is the more
// conventional location but would require adding
// @executable_path/../Frameworks by hand for no offsetting benefit here.
private let framework = app.appending(path: "Contents/MacOS/Sparkle.framework")

/// Runs `codesign` and captures stdout+stderr together — `-dvv` and
/// `--verify` diagnostics both go to stderr, which a prior version of this
/// helper discarded, leaving assertion failures with no clue why codesign
/// disagreed.
private func runCodesign(_ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, "failed to launch codesign: \(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// Runs `codesign --verify --deep --strict` against a path and reports
/// whether it exited zero, plus the diagnostic text on failure.
private func codesignVerifies(_ url: URL) -> (ok: Bool, diagnostics: String) {
    let (status, output) = runCodesign(["--verify", "--deep", "--strict", url.path])
    return (status == 0, output)
}

/// The `Authority=` line from `codesign -dvv`, or nil if not found. `adhoc`
/// signatures print no `Authority=` line at all, so a vendor-signed,
/// never-re-signed framework reads back as nil here, not as some
/// placeholder string — that's the discriminator this file relies on.
private func codesignAuthority(_ url: URL) -> String? {
    let (_, output) = runCodesign(["-dvv", url.path])
    for line in output.split(separator: "\n") where line.hasPrefix("Authority=") {
        return String(line.dropFirst("Authority=".count))
    }
    return nil
}

private func plistOf(_ app: URL) throws -> [String: Any] {
    let plistURL = app.appending(path: "Contents/Info.plist")
    let data = try Data(contentsOf: plistURL)
    let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    return try #require(plist as? [String: Any])
}

@Test("The built app embeds Sparkle.framework at Contents/MacOS", .enabled(if: appIsBuilt || requireAppBundle, appBundleSkipReason))
func builtAppEmbedsSparkleAtChosenLocation() throws {
    try #require(appIsBuilt, appBundleSkipReason)
    #expect(FileManager.default.fileExists(atPath: framework.path))
}

@Test(
    "Both the embedded framework and the outer app verify with codesign --deep --strict",
    .enabled(if: appIsBuilt || requireAppBundle, appBundleSkipReason)
)
func frameworkAndAppAreBothSigned() throws {
    try #require(appIsBuilt, appBundleSkipReason)
    try #require(FileManager.default.fileExists(atPath: framework.path), "Sparkle.framework missing — cannot test signing")

    // Keep this test even though it has a known gap (below): it is the
    // ONLY test in this file that catches SEAL INTEGRITY — the outer app's
    // CodeResources pinning a nested item's designated requirement and then
    // that nested item changing underneath it ("nested code is modified or
    // invalid"). Hit this by accident once, restoring the framework without
    // re-signing the app afterward — `frameworkCarriesAppsSigningIdentity`
    // (an Authority= string comparison) passed straight through that,
    // because both sides still nominally had an Authority; this test was
    // the only one that failed.
    //
    // The gap: it does NOT catch every wrong implementation. SPM's vendored
    // Sparkle.framework arrives already signed ad-hoc by Sparkle's own
    // build, so leaving it untouched (never re-signing it with Snitt's
    // identity at all) still verifies here, PROVIDED the app is re-signed
    // consistently against that same still-ad-hoc framework — ad-hoc counts
    // as "signed" for --deep --strict. Confirmed by direct mutation
    // (rebuilt via a make-app.sh with every framework-level sign_nested
    // call removed, so app and framework are self-consistent): this test
    // passes. `frameworkCarriesAppsSigningIdentity` below is what catches
    // that specific gap; this test alone cannot discriminate it. Two
    // distinct properties, two tests — neither is redundant with the
    // other.
    let frameworkResult = codesignVerifies(framework)
    #expect(frameworkResult.ok, "Sparkle.framework does not verify:\n\(frameworkResult.diagnostics)")

    let appResult = codesignVerifies(app)
    #expect(appResult.ok, "Snitt.app does not verify --deep --strict:\n\(appResult.diagnostics)")
}

@Test(
    "The embedded framework carries Snitt's own signing identity, not the vendor's ad-hoc one",
    .enabled(if: appIsBuilt || requireAppBundle, appBundleSkipReason)
)
func frameworkCarriesAppsSigningIdentity() throws {
    try #require(appIsBuilt, appBundleSkipReason)
    try #require(FileManager.default.fileExists(atPath: framework.path), "Sparkle.framework missing")

    // Catches exactly the gap `frameworkAndAppAreBothSigned` cannot: if
    // make-app.sh's re-sign step for the framework were ever dropped (while
    // still signing the app), the framework would keep SPM's vendor ad-hoc
    // signature — `codesign -dvv` prints no `Authority=` line for that — and
    // this fails even though --deep --strict above still passes. Verified
    // by direct mutation: copying a freshly-built, never-re-signed
    // Sparkle.framework into the bundle (app still signed normally) makes
    // this assertion fail while `frameworkAndAppAreBothSigned` keeps
    // passing.
    let frameworkAuthority = codesignAuthority(framework)
    let appAuthority = codesignAuthority(app)

    #expect(frameworkAuthority != nil, "Sparkle.framework has no Authority= (ad-hoc/vendor signature never replaced)")
    #expect(frameworkAuthority == appAuthority, "framework Authority (\(frameworkAuthority ?? "nil")) != app Authority (\(appAuthority ?? "nil"))")
}

@Test(
    "The app binary carries the @loader_path rpath the Contents/MacOS embedding decision depends on",
    .enabled(if: appIsBuilt || requireAppBundle, appBundleSkipReason)
)
func appBinaryLinksSparkleViaLoaderPath() throws {
    try #require(appIsBuilt, appBundleSkipReason)
    let binary = app.appending(path: "Contents/MacOS/Snitt")
    try #require(FileManager.default.fileExists(atPath: binary.path))

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
    process.arguments = ["-l", binary.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: data, encoding: .utf8) ?? ""

    // What this actually is: a toolchain canary, NOT a location-regression
    // check. Both strings it looks for — the `LC_RPATH path @loader_path`
    // and the `LC_LOAD_DYLIB name @rpath/Sparkle.framework/...` — are baked
    // into this binary by the Swift linker when SnittApp is built;
    // make-app.sh's packaging step never touches either. Confirmed by
    // direct mutation: moving the embedded framework to Contents/Frameworks
    // (a real location regression) makes `builtAppEmbedsSparkleAtChosenLocation`
    // fail and makes the app fail to actually launch (dyld: Library not
    // loaded), but leaves THIS test passing unchanged — it has no way to
    // detect that regression. Its only genuine value: if a future SwiftPM
    // ever emitted a different rpath (e.g. @executable_path/../Frameworks)
    // for this target, embedding at Contents/MacOS/ would silently stop
    // working and this is the one test that would notice, because the
    // rationale in make-app.sh's comment depends on this exact rpath being
    // true. `builtAppEmbedsSparkleAtChosenLocation` is the actual location
    // check; this is not a substitute for it.
    #expect(output.contains("@loader_path"), "no @loader_path rpath — the Contents/MacOS embedding decision assumes this")
    #expect(output.contains("Sparkle.framework"), "binary does not reference Sparkle.framework at all")
}

@Test(
    "Sparkle never links into snitt-cli or snitt-mcp — the thin client boundary (§4.9)"
)
func sparkleNeverLinksIntoThinClients() throws {
    // Deliberately not gated on appIsBuilt: SnittCLITests/SnittMCPTests
    // already depend on the snitt-cli/snitt-mcp targets, so `swift test`
    // builds these binaries regardless of whether make-app.sh has run.
    // Verified by direct mutation: temporarily adding the Sparkle product
    // to snitt-cli's dependencies in Package.swift and rebuilding made this
    // fail with an actual "sparkle" hit from otool; reverting restored the
    // pass. This is the real enforcement for Ruling R2 — the comment in
    // Package.swift used to cite a test and an otool check that did not
    // exist anywhere in the repo.
    for binaryName in ["snitt-cli", "snitt-mcp"] {
        let path = ".build/debug/\(binaryName)"
        try #require(
            FileManager.default.fileExists(atPath: path),
            "\(path) missing — expected swift test to have built it as a test-target dependency"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        process.arguments = ["-L", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""

        #expect(!output.lowercased().contains("sparkle"), "\(binaryName) links Sparkle — §4.9 thin-client boundary broken:\n\(output)")
    }
}

@Test("Info.plist declares Sparkle's feed, omits the EdDSA key placeholder, and defaults automatic checks off", .enabled(if: appIsBuilt || requireAppBundle, appBundleSkipReason))
func infoPlistDeclaresSparkleKeys() throws {
    try #require(appIsBuilt, appBundleSkipReason)
    let plist = try plistOf(app)

    #expect(plist["SUFeedURL"] != nil)
    // NOT `!= nil` here: an empty-string SUPublicEDKey is a DIFFERENT and
    // worse state than an absent one (see make-app.sh's comment) — it makes
    // Sparkle refuse to start at all, rather than falling back to
    // code-signing validation. So this key must be genuinely absent from
    // the plist until a real key exists.
    #expect(plist["SUPublicEDKey"] == nil, "SUPublicEDKey should be entirely absent, not an empty placeholder — see make-app.sh")
    // Ruling R3: false is the cold-start default. An update check is a
    // network request announcing this machine runs Snitt, made at a moment
    // the user did not choose. Task 3 adds a user-facing setting that
    // governs this at runtime; until then, the plist must not opt a fresh
    // install into checking.
    #expect(plist["SUEnableAutomaticChecks"] as? Bool == false)
}

/// A `SPUUserDriver` that does nothing. Sparkle requires one to construct an
/// `SPUUpdater`, but `startUpdater()` only needs to run its own
/// configuration validation synchronously — nothing here should ever
/// actually be invoked in this test, since there's no user interaction and
/// automatic checks are off.
@MainActor
private final class NoopUserDriver: NSObject, SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {}
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {}
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {}
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {}
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {}
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {}
    func dismissUpdateInstallation() {}
}

@Test(
    "Sparkle's own SPUUpdater.startUpdater() accepts the built bundle's configuration",
    .enabled(if: appIsBuilt || requireAppBundle, appBundleSkipReason)
)
@MainActor
func sparkleAcceptsTheBuiltBundleConfiguration() throws {
    try #require(appIsBuilt, appBundleSkipReason)
    // This is what R5 asked for instead of one more key-presence assertion:
    // drive Sparkle's OWN configuration validation
    // (SPUUpdater.startUpdater(), which calls Sparkle's internal
    // checkIfConfiguredProperlyAndRequireFeedURL: before doing anything
    // else) against the real built bundle, rather than asserting that
    // individual plist keys merely exist.
    //
    // Catches the actual defect this task shipped with: the built plist had
    // three correct SU* keys and no CFBundleVersion. SUHost.validVersion
    // (Sparkle 2.9.6 source) reads ONLY CFBundleVersion, and
    // checkIfConfiguredProperlyAndRequireFeedURL: bails with
    // SUInvalidHostVersionError before it even looks at the SU* keys, so
    // Task 3's updater would never start. Verified by direct mutation:
    // removing CFBundleVersion from a copy of the built Info.plist and
    // re-running this test (against a temp bundle copy) fails with exactly
    // that error; restoring it passes.
    let bundle = try #require(Bundle(url: app), "could not open build/Snitt.app as a bundle")
    let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: NoopUserDriver(), delegate: nil)
    try updater.start()
}

// MARK: - R9/R10: com.apple.security.cs.disable-library-validation must be conditional

/// Runs `Scripts/lib/needs-teamless-workaround.sh` — the exact decision
/// `make-app.sh` uses — with a synthetic `codesign -dvv` TeamIdentifier
/// line, and returns "yes" or "no".
private func needsTeamlessWorkaround(forTeamIdentifierLine line: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "Scripts/lib/needs-teamless-workaround.sh")
    process.arguments = [line]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func hasDisableLibraryValidation(_ entitlementsXML: String) -> Bool {
    entitlementsXML.contains("com.apple.security.cs.disable-library-validation")
}

private func realTeamIdentifierLine(of url: URL) -> String {
    let (_, output) = runCodesign(["-dvv", url.path])
    for line in output.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
        return String(line)
    }
    return "TeamIdentifier=not set"
}

private func entitlementsXML(of url: URL) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["-d", "--entitlements", "-", "--xml", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return ""
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// The one property R9/R10 exist to guarantee: a build signed under a real
/// (non-teamless) identity must not carry the library-validation
/// workaround. Used by `appEntitlementsCarryNoWorkaroundLeakUnderARealTeamID`
/// below, which can currently only ever hit the teamless branch against the
/// real production build — see
/// `signingWithADeveloperIDShapedIdentityCarriesNoWorkaround` for the real,
/// non-fixture exercise of the other branch.
private func assertNoWorkaroundLeak(teamIdentifierLine: String, entitlementsXML: String) throws {
    let needsWorkaround = try needsTeamlessWorkaround(forTeamIdentifierLine: teamIdentifierLine) == "yes"
    if !needsWorkaround {
        #expect(
            !hasDisableLibraryValidation(entitlementsXML),
            "a Developer-ID-shaped build (\(teamIdentifierLine)) must not carry disable-library-validation"
        )
    }
}

@Test(
    "R9's decision script adds the workaround only for a teamless identity (self-signed/ad-hoc)"
)
func teamlessWorkaroundScriptDecidesCorrectly() throws {
    // Not gated on appIsBuilt: this calls the standalone decision script
    // directly with synthetic input, so it needs no built bundle and no
    // real signing identity of any kind.
    //
    // Verified by mutation: temporarily inverted the shell script's
    // if/else (so it answered "no" for a teamless identity) — this test
    // failed on the first assertion; reverting restored the pass.
    #expect(try needsTeamlessWorkaround(forTeamIdentifierLine: "TeamIdentifier=not set") == "yes")
    #expect(try needsTeamlessWorkaround(forTeamIdentifierLine: "TeamIdentifier=ABCDE12345TEAM") == "no")
}

@Test(
    "Signing with a Developer-ID-shaped identity, via the real production script, carries no library-validation workaround",
    .enabled(if: appIsBuilt || requireAppBundle, appBundleSkipReason)
)
func signingWithADeveloperIDShapedIdentityCarriesNoWorkaround() throws {
    try #require(appIsBuilt, appBundleSkipReason)

    // R13: the test this replaced asserted a string match against a
    // literal it wrote itself, gated on a script answer
    // teamlessWorkaroundScriptDecidesCorrectly already asserts. It never
    // touched entitlementsXML(of:) — the only production-facing input —
    // and never touched make-app.sh, so "the entitlement applied
    // unconditionally" (the exact defect R9 exists to prevent) was
    // invisible to it on every machine that can run this suite.
    //
    // This test instead runs the REAL production script,
    // Scripts/lib/sign-app-with-workaround.sh (the one make-app.sh
    // itself calls), against a real copy of the built app, injecting a
    // Developer-ID-shaped TeamIdentifier via
    // SNITT_FAKE_TEAM_IDENTIFIER_LINE — the one deliberate seam that
    // exists only because no real paid Developer ID is available in this
    // repo to produce that signature end-to-end — and inspects the REAL
    // resulting signature and entitlements, not a fixture.
    //
    // Verified this fails against the wrong implementation it exists to
    // catch: temporarily edited sign-app-with-workaround.sh to add the
    // entitlement unconditionally (removing the `if`) and re-ran this
    // test — it failed on the real re-signed copy's entitlements; reverting
    // restored the pass. See task-2-report.md.
    let tempDir = FileManager.default.temporaryDirectory.appending(path: "snitt-sign-test-\(UUID().uuidString)")
    let copy = tempDir.appending(path: "Snitt.app")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.copyItem(at: app, to: copy)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "Scripts/lib/sign-app-with-workaround.sh")
    process.arguments = [copy.path, "-"]
    // Explicit environment, not inherited — matching the discipline
    // `AppcastTests`, `NotarizeScriptTests` and `SignAppWithWorkaroundTests`
    // each adopted: a real developer machine could have
    // SNITT_FAKE_TEAM_IDENTIFIER_LINE already exported from an earlier test
    // session, and inheriting the process environment would let this
    // specific test pass (or, worse, silently pick up a stray override) for
    // the wrong reason instead of the one line set below. Only `codesign`
    // needs to resolve from PATH here.
    process.environment = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "SNITT_FAKE_TEAM_IDENTIFIER_LINE": "TeamIdentifier=ABCDE12345TEAM",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 0, "sign-app-with-workaround.sh failed:\n\(output)")

    let verify = codesignVerifies(copy)
    #expect(verify.ok, "re-signed copy does not verify --deep --strict:\n\(verify.diagnostics)")

    let xml = entitlementsXML(of: copy)
    #expect(!hasDisableLibraryValidation(xml), "a Developer-ID-shaped identity (real signature) must not carry disable-library-validation:\n\(xml)")
}

@Test(
    "The real built app carries no library-validation workaround under a real Team ID",
    .enabled(if: appIsBuilt || requireAppBundle, appBundleSkipReason)
)
func appEntitlementsCarryNoWorkaroundLeakUnderARealTeamID() throws {
    try #require(appIsBuilt, appBundleSkipReason)

    // This can only ever exercise the teamless branch today (see
    // signingWithADeveloperIDShapedIdentityCarriesNoWorkaround for the
    // Developer-ID-shaped case, which this repo cannot produce with a real
    // signature). Under
    // the self-signed dev identity, make-app.sh is EXPECTED to add the
    // workaround, so assert that expectation explicitly rather than
    // silently doing nothing — a real integration check that never
    // executes its own guard clause is as good as no check at all.
    let teamLine = realTeamIdentifierLine(of: app)
    let xml = entitlementsXML(of: app)
    if try needsTeamlessWorkaround(forTeamIdentifierLine: teamLine) == "yes" {
        #expect(hasDisableLibraryValidation(xml), "teamless build (\(teamLine)) should carry the workaround, but doesn't")
    } else {
        try assertNoWorkaroundLeak(teamIdentifierLine: teamLine, entitlementsXML: xml)
    }
}
