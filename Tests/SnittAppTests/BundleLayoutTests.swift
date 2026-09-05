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
// this file — the condition trait means it exercises none of it silently,
// which is the honest failure mode for a check that fundamentally needs a
// built artifact. See the task report.

private let app = URL(fileURLWithPath: "build/Snitt.app")
private let appIsBuilt = FileManager.default.fileExists(atPath: app.path)

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

@Test("The built app embeds Sparkle.framework at Contents/MacOS", .enabled(if: appIsBuilt, "run ./Scripts/make-app.sh first"))
func builtAppEmbedsSparkleAtChosenLocation() throws {
    #expect(FileManager.default.fileExists(atPath: framework.path))
}

@Test(
    "Both the embedded framework and the outer app verify with codesign --deep --strict",
    .enabled(if: appIsBuilt, "run ./Scripts/make-app.sh first")
)
func frameworkAndAppAreBothSigned() throws {
    try #require(FileManager.default.fileExists(atPath: framework.path), "Sparkle.framework missing — cannot test signing")

    // This check catches the framework being absent or its signature being
    // stripped/corrupted entirely. It does NOT catch every wrong
    // implementation: SPM's vendored Sparkle.framework arrives already
    // signed ad-hoc by Sparkle's own build, so leaving it untouched (never
    // re-signing it with Snitt's identity at all) still verifies here —
    // ad-hoc counts as "signed" for --deep --strict. Confirmed by direct
    // mutation (never re-sign the framework, only sign the app): this test
    // still passes. `frameworkCarriesAppsSigningIdentity` below is what
    // catches that specific gap; this test alone cannot discriminate it.
    let frameworkResult = codesignVerifies(framework)
    #expect(frameworkResult.ok, "Sparkle.framework does not verify:\n\(frameworkResult.diagnostics)")

    let appResult = codesignVerifies(app)
    #expect(appResult.ok, "Snitt.app does not verify --deep --strict:\n\(appResult.diagnostics)")
}

@Test(
    "The embedded framework carries Snitt's own signing identity, not the vendor's ad-hoc one",
    .enabled(if: appIsBuilt, "run ./Scripts/make-app.sh first")
)
func frameworkCarriesAppsSigningIdentity() throws {
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
    "The app binary links Sparkle via @loader_path, matching where it's embedded",
    .enabled(if: appIsBuilt, "run ./Scripts/make-app.sh first")
)
func appBinaryLinksSparkleViaLoaderPath() throws {
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

    // Catches Contents/Frameworks embedding without the matching rpath: if
    // make-app.sh's location and the binary's actual rpath ever disagreed,
    // Sparkle would fail to load at runtime (a launch-time crash, not a
    // build or codesign failure) despite every signing check above passing.
    #expect(output.contains("@loader_path"), "no @loader_path rpath — Contents/MacOS embedding requires it")
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

@Test("Info.plist declares Sparkle's feed, omits the EdDSA key placeholder, and defaults automatic checks off", .enabled(if: appIsBuilt, "run ./Scripts/make-app.sh first"))
func infoPlistDeclaresSparkleKeys() throws {
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
    .enabled(if: appIsBuilt, "run ./Scripts/make-app.sh first")
)
@MainActor
func sparkleAcceptsTheBuiltBundleConfiguration() throws {
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
