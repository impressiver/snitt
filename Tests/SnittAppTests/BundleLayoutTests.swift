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

@Test("Info.plist declares Sparkle's feed, a usable EdDSA key, and defaults automatic checks off", .enabled(if: appIsBuilt || requireAppBundle, appBundleSkipReason))
func infoPlistDeclaresSparkleKeys() throws {
    try #require(appIsBuilt, appBundleSkipReason)
    let plist = try plistOf(app)

    #expect(plist["SUFeedURL"] != nil)
    // NOT `!= nil`: the states that break Sparkle are all non-nil. An empty
    // string, or anything that isn't exactly 32 decoded bytes, reads as
    // SUSigningInputStatusInvalid and SPUUpdater then refuses to start at
    // all with SUNoPublicDSAFoundError — a worse failure than having no key,
    // because it takes the whole updater down rather than falling back to
    // code-signing validation. So assert the shape Sparkle can actually use.
    // (An absent key is a legitimate state too — see make-app.sh — but this
    // build ships a real one, and silently losing it must fail here.)
    let edKey = try #require(plist["SUPublicEDKey"] as? String, "SUPublicEDKey is missing — see make-app.sh")
    let decoded = try #require(Data(base64Encoded: edKey), "SUPublicEDKey is not valid base64: \(edKey)")
    #expect(decoded.count == 32, "Ed25519 public keys are 32 bytes; SUPublicEDKey decoded to \(decoded.count)")
    // Ruling R3: false is the cold-start default. An update check is a
    // network request announcing this machine runs Snitt, made at a moment
    // the user did not choose. Task 3 adds a user-facing setting that
    // governs this at runtime; until then, the plist must not opt a fresh
    // install into checking.
    #expect(plist["SUEnableAutomaticChecks"] as? Bool == false)
}

@Test("The built app declares .snitt as an openable package type", .enabled(if: appIsBuilt || requireAppBundle, appBundleSkipReason))
func infoPlistDeclaresDocumentType() throws {
    try #require(appIsBuilt, appBundleSkipReason)
    let plist = try plistOf(app)

    let exported = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
    let snitt = try #require(exported.first { ($0["UTTypeIdentifier"] as? String) == "com.impressiver.snitt.recording" },
                             "no exported UTI for .snitt")

    // A .snitt is a DIRECTORY. Without com.apple.package the Finder shows a
    // folder and a double-click navigates into it instead of opening it —
    // the app looks broken while every key is nominally present.
    let conforms = try #require(snitt["UTTypeConformsTo"] as? [String])
    #expect(conforms.contains("com.apple.package"))

    let tags = try #require(snitt["UTTypeTagSpecification"] as? [String: Any])
    let extensions = try #require(tags["public.filename-extension"] as? [String])
    #expect(extensions.contains("snitt"))

    let docTypes = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
    let docType = try #require(docTypes.first, "no CFBundleDocumentTypes entry")
    let contentTypes = try #require(docType["LSItemContentTypes"] as? [String])

    // The two must AGREE. A document type naming a UTI the app does not
    // export is the same silent-drift class as SUFeedURL vs appcast.xml:
    // both halves look right in isolation and nothing opens.
    #expect(contentTypes.contains("com.impressiver.snitt.recording"))
    #expect(docType["CFBundleTypeRole"] as? String == "Editor")
    #expect(docType["LSTypeIsPackage"] as? Bool == true)
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
func sparkleAcceptsTheBuiltBundleConfiguration() async throws {
    try #require(appIsBuilt, appBundleSkipReason)
    // `SparkleTestGate` (Tests/SnittAppTests/SparkleTestGate.swift): starts
    // a real `SPUUpdater` against the real built bundle. `AppcastTests.swift`
    // and `UpdaterControllerTests.swift` each drive a real `SPUUpdater` too,
    // as unserialized top-level tests, so without this gate `startUpdater()`
    // here can race their XPC/scheduler activity.
    try await SparkleTestGate.run {
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

// MARK: - Secure timestamp (M5b notary defect): every codesign call must timestamp

// Apple's notary service rejected the first real submission on all three
// signed things (Snitt.app, Updater.app, both Sparkle XPC services) with
// "The signature does not include a secure timestamp." No LOCAL check
// catches this: `codesign --verify --deep --strict` passes on an
// untimestamped signature, and so does launching the app — only Apple's
// service looks. The one local observable that DOES exist is `codesign
// -dvv` printing a `Timestamp=<date>` line, confirmed directly (not
// assumed) to appear only for a securely-timestamped signature.
//
// This defect is exactly the shape this project has hit twenty-six times
// before: three separate codesign call sites (Scripts/make-app.sh's
// sign_nested → Scripts/lib/sign-nested-item.sh; and
// Scripts/lib/sign-app-with-workaround.sh's two calls, one per branch of
// its teamless-workaround decision), and a test that only checks a
// property true of all three regardless of which one is broken would miss
// exactly the same bug in a smaller way. So each test below is pinned to
// ONE call site and asserts on the ACTUAL on-disk signature that call site
// alone produces — not a fixture, not a string comparison against the
// script's own source.
//
// Confirmed directly, and load-bearing for the gating below: `--timestamp`
// is a silent no-op for ad-hoc signing (`-`) — no `Timestamp=` line, no
// network attempt even against a deliberately unreachable server, exit 0
// — but for a REAL (non-ad-hoc) identity, an unreachable timestamp server
// makes codesign FAIL the whole signing call outright. So verifying a
// REAL secure timestamp locally requires both a real signing identity AND
// working network access to Apple's timestamp service; these tests gate on
// having confirmed both, live, rather than assuming either.

/// `Scripts/signing-identity.sh`'s stable identity name, or nil if that
/// script exits non-zero (no such identity installed on this machine).
private let stableSigningIdentity: String? = {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "Scripts/signing-identity.sh")
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (name?.isEmpty == false) ? name : nil
}()

/// Whether `codesign --timestamp` can actually reach Apple's timestamp
/// service, right now, under the stable signing identity — determined by
/// really trying it against a throwaway file, not assumed from "network
/// looks up". A real, non-ad-hoc identity is required for this probe:
/// ad-hoc's `--timestamp` is a confirmed no-op regardless of reachability,
/// so probing with `-` would always read as "reachable" even when offline.
private let timestampServiceReachable: Bool = {
    guard let identity = stableSigningIdentity else { return false }
    let probe = FileManager.default.temporaryDirectory.appending(path: "snitt-timestamp-probe-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: probe.path, contents: Data("probe".utf8))
    defer { try? FileManager.default.removeItem(at: probe) }
    let (status, _) = runCodesign(["--force", "--sign", identity, "--timestamp", probe.path])
    return status == 0
}()

private let timestampSkipReason: Comment =
    "needs both Scripts/signing-identity.sh's stable identity installed and live network access to Apple's timestamp service — see stableSigningIdentity/timestampServiceReachable"

/// Runs one of the two testable signing lib scripts against a fresh copy
/// of the built app (or, for sign-nested-item.sh, a fresh copy of one
/// nested item), returning (exit status, combined output).
private func runScript(_ path: String, arguments: [String], environment: [String: String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, "failed to launch \(path): \(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

@Test(
    "Secure timestamp: sign-nested-item.sh's codesign call timestamps a nested Sparkle item",
    .enabled(if: appIsBuilt && timestampServiceReachable, timestampSkipReason)
)
func signNestedItemTimestampsTheItem() throws {
    try #require(appIsBuilt, appBundleSkipReason)
    let identity = try #require(stableSigningIdentity)

    // Verified this fails against the wrong implementation it exists to
    // catch: temporarily removed --timestamp from
    // Scripts/lib/sign-nested-item.sh's codesign call and re-ran this
    // test — it failed on the missing Timestamp= line for this exact
    // item; reverting restored the pass. The other two timestamp tests
    // below did NOT fail from that same mutation, confirming this test is
    // pinned to sign-nested-item.sh alone.
    let source = framework.appending(path: "Versions/B/Updater.app")
    try #require(FileManager.default.fileExists(atPath: source.path), "Updater.app missing — build/Snitt.app not fully assembled")

    let tempDir = FileManager.default.temporaryDirectory.appending(path: "snitt-nested-timestamp-\(UUID().uuidString)")
    let copy = tempDir.appending(path: "Updater.app")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.copyItem(at: source, to: copy)

    let (status, output) = runScript(
        "Scripts/lib/sign-nested-item.sh",
        arguments: [copy.path, identity],
        environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    )
    #expect(status == 0, "sign-nested-item.sh failed:\n\(output)")

    let (_, dvv) = runCodesign(["-dvv", copy.path])
    #expect(dvv.contains("Timestamp="), "expected a secure timestamp on a sign-nested-item.sh signature:\n\(dvv)")
}

@Test(
    "Secure timestamp: sign-app-with-workaround.sh's initial app sign (Developer-ID-shaped branch) timestamps the app",
    .enabled(if: appIsBuilt && timestampServiceReachable, timestampSkipReason)
)
func initialAppSignIsTimestamped() throws {
    try #require(appIsBuilt, appBundleSkipReason)
    let identity = try #require(stableSigningIdentity)

    // Forcing a Developer-ID-shaped TeamIdentifier (as
    // signingWithADeveloperIDShapedIdentityCarriesNoWorkaround above
    // already does) takes the "no real Team ID? no" branch, which skips
    // the entitlements re-sign entirely — so the on-disk signature this
    // test inspects is produced by ONLY the first codesign call (line 52),
    // not overwritten by the second. That isolates this test to that one
    // call site.
    //
    // Verified this fails against the wrong implementation: temporarily
    // removed --timestamp from just this first codesign call in
    // sign-app-with-workaround.sh and re-ran — this test failed on the
    // missing Timestamp= line while workaroundResignIsTimestamped below
    // (which exercises the OTHER call) still passed, confirming isolation
    // in both directions.
    let tempDir = FileManager.default.temporaryDirectory.appending(path: "snitt-initial-sign-timestamp-\(UUID().uuidString)")
    let copy = tempDir.appending(path: "Snitt.app")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.copyItem(at: app, to: copy)

    let (status, output) = runScript(
        "Scripts/lib/sign-app-with-workaround.sh",
        arguments: [copy.path, identity],
        environment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "SNITT_FAKE_TEAM_IDENTIFIER_LINE": "TeamIdentifier=ABCDE12345TEAM",
        ]
    )
    #expect(status == 0, "sign-app-with-workaround.sh failed:\n\(output)")

    let (_, dvv) = runCodesign(["-dvv", copy.path])
    #expect(dvv.contains("Timestamp="), "expected a secure timestamp on the initial (Developer-ID-shaped-branch) app sign:\n\(dvv)")
}

@Test(
    "Secure timestamp: sign-app-with-workaround.sh's teamless-workaround re-sign timestamps the app",
    .enabled(if: appIsBuilt && timestampServiceReachable, timestampSkipReason)
)
func workaroundResignIsTimestamped() throws {
    try #require(appIsBuilt, appBundleSkipReason)
    let identity = try #require(stableSigningIdentity)

    // No SNITT_FAKE_TEAM_IDENTIFIER_LINE override here: a self-signed
    // identity naturally reads back "TeamIdentifier=not set", taking the
    // "yes" branch, whose entitlements re-sign (line 109) runs SECOND and
    // so is what's actually on disk afterward — isolating this test to
    // that call site, distinct from initialAppSignIsTimestamped above.
    //
    // Verified this fails against the wrong implementation: temporarily
    // removed --timestamp from just this second (entitlements re-sign)
    // codesign call and re-ran — this test failed on the missing
    // Timestamp= line while initialAppSignIsTimestamped above still
    // passed.
    let tempDir = FileManager.default.temporaryDirectory.appending(path: "snitt-workaround-resign-timestamp-\(UUID().uuidString)")
    let copy = tempDir.appending(path: "Snitt.app")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.copyItem(at: app, to: copy)

    let (status, output) = runScript(
        "Scripts/lib/sign-app-with-workaround.sh",
        arguments: [copy.path, identity],
        environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    )
    #expect(status == 0, "sign-app-with-workaround.sh failed:\n\(output)")

    let teamLine = realTeamIdentifierLine(of: copy)
    try #require(try needsTeamlessWorkaround(forTeamIdentifierLine: teamLine) == "yes", "expected the self-signed identity to take the teamless-workaround branch (got \(teamLine)) — cannot isolate the re-sign call otherwise")

    let (_, dvv) = runCodesign(["-dvv", copy.path])
    #expect(dvv.contains("Timestamp="), "expected a secure timestamp on the teamless-workaround re-sign:\n\(dvv)")
}

@Test("SNITT_SKIP_TIMESTAMP=1 omits the secure timestamp (offline opt-out actually opts out)")
func skipTimestampEnvVarActuallySkipsIt() throws {
    // Ad-hoc signing needs no real identity and no network — this proves
    // the opt-out variable is wired to sign-nested-item.sh's codesign call
    // without depending on the network-gated tests above. (--timestamp is
    // already a no-op for ad-hoc, so this doesn't prove much about ad-hoc
    // specifically; it proves SNITT_SKIP_TIMESTAMP reaches the flag at
    // all, which the network-gated tests above can't check when skipped.)
    let tempFile = FileManager.default.temporaryDirectory.appending(path: "snitt-skip-timestamp-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: tempFile.path, contents: Data("probe".utf8))
    defer { try? FileManager.default.removeItem(at: tempFile) }

    let (status, output) = runScript(
        "Scripts/lib/sign-nested-item.sh",
        arguments: [tempFile.path, "-"],
        environment: [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "SNITT_SKIP_TIMESTAMP": "1",
        ]
    )
    #expect(status == 0, "sign-nested-item.sh failed:\n\(output)")
    let (_, dvv) = runCodesign(["-dvv", tempFile.path])
    #expect(!dvv.contains("Timestamp="), "SNITT_SKIP_TIMESTAMP=1 should omit the secure timestamp:\n\(dvv)")
}

// make-app.sh writes Info.plist from a heredoc whose delimiter is
// deliberately UNQUOTED — $APP_VERSION and $BUNDLE_ID have to expand. That
// also makes backticks inside the body command substitution, so prose like
//   the key `sign_update` signs with
// runs `sign_update`, prints "command not found" to stderr, and silently
// substitutes empty into the shipped plist. Both a real instance of that
// (the words vanished from two comments) and its predecessor shipped before
// anyone noticed: the plist still parsed, every key was still correct, and
// the only symptom was two lines of build noise.
//
// These two tests pin the class rather than the two instances. The first
// catches any backtick reintroduced into the heredoc body — the mechanism.
// The second catches the observable damage in the generated plist, so a
// future heredoc built some other way is still covered.
private let makeAppScript = URL(fileURLWithPath: "Scripts/make-app.sh")

@Test("make-app.sh's Info.plist heredoc contains no backticks, which the unquoted delimiter would execute")
func infoPlistHeredocHasNoCommandSubstitution() throws {
    let source = try String(contentsOf: makeAppScript, encoding: .utf8)
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

    // The heredoc runs from the `<<PLIST` line to the closing `PLIST`.
    let start = try #require(lines.firstIndex { $0.hasSuffix("<<PLIST") }, "make-app.sh no longer has a <<PLIST heredoc — update this test")
    let end = try #require(lines[start...].firstIndex { $0 == "PLIST" }, "unterminated <<PLIST heredoc in make-app.sh")

    let offenders = lines[start...end].enumerated()
        .filter { $0.element.contains("`") }
        .map { "line \(start + $0.offset + 1): \($0.element)" }

    #expect(offenders.isEmpty, """
        Backticks inside make-app.sh's unquoted heredoc are executed as commands, \
        and their output replaces the text in the generated Info.plist. \
        Use plain words or single quotes in that prose:
        \(offenders.joined(separator: "\n"))
        """)
}

@Test(
    "The built app declares an app icon, and the file it names actually exists in the bundle",
    .enabled(if: appIsBuilt || requireAppBundle, appBundleSkipReason)
)
func infoPlistDeclaresAnIconThatActuallyExists() throws {
    try #require(appIsBuilt, appBundleSkipReason)
    let plist = try plistOf(app)

    // A missing CFBundleIconFile is the observable Task 9 exists to fix —
    // Snitt shows the generic document icon in the Dock, the Finder, and
    // Cmd-Tab without it.
    let iconFile = try #require(plist["CFBundleIconFile"] as? String, "CFBundleIconFile missing from Info.plist")

    // The adjacent-property trap this project has hit twenty-six times: a
    // plist naming a FILE THAT ISN'T THERE produces the exact same generic
    // icon as no declaration at all, while every key still looks correct
    // in isolation. `CFBundleIconFile` is conventionally written without
    // the ".icns" extension (AppKit appends it), so check both spellings —
    // whichever make-app.sh actually wrote, the file it names must be on
    // disk in Contents/Resources.
    let resources = app.appending(path: "Contents/Resources")
    let withExtension = iconFile.hasSuffix(".icns") ? iconFile : "\(iconFile).icns"
    let bareIconPath = resources.appending(path: iconFile).path
    let icnsIconPath = resources.appending(path: withExtension).path
    let iconExists = FileManager.default.fileExists(atPath: bareIconPath)
        || FileManager.default.fileExists(atPath: icnsIconPath)
    #expect(iconExists, "CFBundleIconFile names \"\(iconFile)\", but neither \(bareIconPath) nor \(icnsIconPath) exists")
}

@Test("The generated Info.plist keeps the comment text make-app.sh wrote", .enabled(if: appIsBuilt || requireAppBundle, appBundleSkipReason))
func infoPlistCommentsSurviveGeneration() throws {
    try #require(appIsBuilt, appBundleSkipReason)
    let plistText = try String(contentsOf: app.appending(path: "Contents/Info.plist"), encoding: .utf8)

    // Both words were eaten by command substitution before this was fixed.
    // Asserting on the *generated* file, not on the script, is what makes
    // this catch the damage rather than the mechanism.
    #expect(plistText.contains("sign_update"), "the sign_update reference vanished from the generated plist — command substitution in the heredoc?")
    #expect(plistText.contains("--output"), "the --output reference vanished from the generated plist — command substitution in the heredoc?")
}

// ─── The client frontends ship inside the bundle (D63) ───────────────────────
//
// Until v0.1.0 they did not: make-app.sh copied SnittApp, Sparkle and the icon
// and nothing else, so an installed Snitt.app carried no `snitt` and no
// `snitt-mcp` anywhere on the machine. §13's second validation question — does
// an agent record with Snitt and attach the result to a PR — was unanswerable
// against the artifact that had been signed, notarized and released.
//
// Contents/Helpers, NOT Contents/MacOS: macOS filesystems are case-insensitive
// by default, so `Contents/MacOS/snitt` and `Contents/MacOS/Snitt` are the same
// path and copying the CLI there REPLACES the app binary with it. That is not
// hypothetical — it happened on the first build after the copy was written, and
// the resulting bundle signed and verified cleanly while launching a
// command-line tool with no UI.
private let helpers = app.appending(path: "Contents/Helpers")
private let clientNames = ["snitt", "snitt-mcp"]

@Test("The built app embeds both client executables", .enabled(if: appIsBuilt || requireAppBundle, appBundleSkipReason))
func builtAppEmbedsClientExecutables() throws {
    try #require(appIsBuilt, appBundleSkipReason)
    for name in clientNames {
        let url = helpers.appending(path: name)
        #expect(FileManager.default.isExecutableFile(atPath: url.path),
                "\(name) is missing or not executable at Contents/Helpers — the agent surface ships nowhere")
    }
}

@Test("No two destinations in make-app.sh differ only by case")
func bundleDestinationsDoNotCollideCaseInsensitively() throws {
    // Checked against the SCRIPT, not the built bundle, because the built
    // bundle cannot show this defect: on a case-insensitive volume the second
    // copy overwrites the first, so afterwards only one file exists and
    // enumerating the result looks perfectly correct. The collision is only
    // visible in the set of paths the script intends to write.
    let script = try String(contentsOf: URL(fileURLWithPath: "Scripts/make-app.sh"), encoding: .utf8)
    let pattern = try NSRegularExpression(pattern: #"\$APP/Contents/[A-Za-z0-9_./-]+"#)
    let paths = Set(pattern.matches(in: script, range: NSRange(script.startIndex..., in: script))
        .compactMap { Range($0.range, in: script).map { String(script[$0]) } })
    #expect(paths.count > 2, "regex matched almost nothing — it has drifted from the script")

    var byLowercase: [String: Set<String>] = [:]
    for path in paths { byLowercase[path.lowercased(), default: []].insert(path) }
    for (lowered, variants) in byLowercase where variants.count > 1 {
        Issue.record("make-app.sh writes \(variants.sorted()) — one path on a case-insensitive volume (\(lowered))")
    }
}

@Test("The embedded clients carry the app's signing identity", .enabled(if: appIsBuilt || requireAppBundle, appBundleSkipReason))
func embeddedClientsCarryAppsSigningIdentity() throws {
    try #require(appIsBuilt, appBundleSkipReason)
    // Nested code that is unsigned, or signed with anything but the app's own
    // identity, fails notarization — the same defect that sent the first real
    // submission back Invalid for Sparkle's XPC services. Copying the binaries
    // in and forgetting to sign them is the obvious wrong implementation, and
    // it is invisible locally: the app still launches.
    let appAuthority = codesignAuthority(app)
    for name in clientNames {
        let authority = codesignAuthority(helpers.appending(path: name))
        #expect(authority != nil, "\(name) has no Authority= — it was embedded but never signed")
        #expect(authority == appAuthority, "\(name) Authority (\(authority ?? "nil")) != app Authority (\(appAuthority ?? "nil"))")
    }
}

@Test("Sparkle never links into the embedded clients either (§4.9)", .enabled(if: appIsBuilt || requireAppBundle, appBundleSkipReason))
func sparkleNeverLinksIntoEmbeddedClients() throws {
    try #require(appIsBuilt, appBundleSkipReason)
    // `sparkleNeverLinksIntoThinClients` asserts this of `.build/debug/`, which
    // is what was BUILT. This asserts it of what SHIPS. They can differ: the
    // copy could name the wrong source, and a bundle carrying an updater-linked
    // client would breach the thin-client boundary in the artifact rather than
    // in the build tree.
    for name in clientNames {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        process.arguments = ["-L", helpers.appending(path: name).path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        #expect(!output.lowercased().contains("sparkle"), "embedded \(name) links Sparkle:\n\(output)")
    }
}

@Test("The embedded MCP server answers initialize with its instructions", .enabled(if: appIsBuilt || requireAppBundle, appBundleSkipReason))
func embeddedMCPServerAnswersInitialize() throws {
    try #require(appIsBuilt, appBundleSkipReason)
    // The whole chain in one assertion: built, copied, renamed, signed, and
    // still able to run and speak JSON-RPC. A binary that is present, executable
    // and correctly signed can still be the wrong binary or a stale one, and
    // every check above would pass. This is also the only place the
    // `instructions` field (D63) is verified through the real process rather
    // than by calling the function that produces it.
    let process = Process()
    process.executableURL = helpers.appending(path: "snitt-mcp")
    let stdin = Pipe(), stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = Pipe()
    try process.run()
    let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"# + "\n"
    stdin.fileHandleForWriting.write(Data(request.utf8))
    // Closing stdin ends the server's readLine loop, so this cannot hang
    // waiting for a process that is waiting for us.
    try stdin.fileHandleForWriting.close()
    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()

    let line = try #require(output.split(separator: "\n").first, "server produced no output")
    let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    let result = try #require(json["result"] as? [String: Any], "no result in: \(line)")
    let instructions = try #require(result["instructions"] as? String, "initialize carried no instructions")
    #expect(instructions.contains("snitt_start_recording"))
}

// A release must ship a universal binary, and must not be able to ship one
// slice because somebody forgot a flag.
//
// Every dependency is already universal — Sparkle carries both slices — so an
// arm64-only Snitt was the single thing stopping it from launching on an Intel
// Mac, and macOS 26 is the last release those can run. Coupling the arch flags
// to SNITT_SIGN_IDENTITY (the release path, see release-runbook.md step 1)
// rather than to a separate opt-in is what makes forgetting impossible.
//
// Read from the script rather than from a built bundle, deliberately: a
// developer's local bundle is built native on purpose, so asserting on
// `lipo -archs build/Snitt.app/...` would either fail for everyone or pass
// vacuously. What is checkable everywhere is that the RULE is still wired.
@Test("A Developer ID build is universal, without needing a second flag")
func releaseBuildsAreUniversal() throws {
    let source = try String(contentsOf: makeAppScript, encoding: .utf8)

    // The release path implies universal — checked at the CONDITION that
    // actually guards the arch flags, not by looking for the variable name
    // somewhere in the file. It appears in the signing block too, so a
    // whole-file search passes against a build that dropped the coupling
    // entirely; a mutant that did exactly that survived the first version of
    // this test.
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
    let archLine = try #require(lines.firstIndex { $0.contains("ARCH_FLAGS=(--arch") },
                                "make-app.sh no longer sets architecture flags")
    let guardLine = try #require(
        lines[..<archLine].lastIndex { $0.hasPrefix("if ") || $0.contains("elif ") },
        "the arch flags are not inside a conditional at all")
    #expect(lines[guardLine].contains("SNITT_SIGN_IDENTITY"),
            "universal is no longer implied by a release build; it reads: \(lines[guardLine])")
    #expect(source.contains("--arch arm64"), "make-app.sh builds no arm64 slice")
    #expect(source.contains("--arch x86_64"),
            "make-app.sh builds only one architecture")

    // And the products are copied from wherever that build actually wrote
    // them. A multi-arch `swift build` writes to .build/apple/Products, not
    // .build/debug — copying from a hardcoded .build/debug would silently
    // package the stale single-arch binary instead.
    #expect(source.contains("PRODUCT_DIR"),
            "the copy step is not parameterised on the build's output directory")
    let copiesFromHardcodedDebug = source
        .split(separator: "\n")
        .filter { $0.contains("cp \"") && $0.contains(".build/debug/") }
    #expect(copiesFromHardcodedDebug.isEmpty,
            "still copying from a hardcoded .build/debug: \(copiesFromHardcodedDebug)")
}

@Test("The bundle carries the standard identifying keys a Mac app is expected to have")
func infoPlistCarriesStandardKeys() throws {
    // Absent, these show up as a blank About box, a vague Finder "Kind", and
    // no category in any listing. None changes behaviour, which is exactly why
    // nobody notices they are missing.
    let source = try String(contentsOf: makeAppScript, encoding: .utf8)
    for key in ["CFBundleInfoDictionaryVersion", "CFBundleDevelopmentRegion",
                "NSPrincipalClass", "LSApplicationCategoryType",
                "NSHumanReadableCopyright"] {
        #expect(source.contains("<key>\(key)</key>"), "Info.plist is missing \(key)")
    }
}
