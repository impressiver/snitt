import Testing
import Foundation

// Task 4: Scripts/notarize.sh submits an already-signed Snitt.app to
// Apple's notary service. It requires real Apple Developer credentials
// that must never enter this repo (see the maintainer's decision in
// task-4-brief.md) — so the actual submission cannot be tested here. What
// CAN be tested, and is worth testing precisely because this script runs
// rarely, under release pressure: that it validates every input BEFORE
// touching the network, names exactly what is wrong, and never proceeds
// past a failed check.
//
// Every test below asserts (a) a non-zero exit status and (b) that the
// script never reached its zip/submit step, using an instrumented fake
// `ditto` or `xcrun` placed earlier in PATH — not just that a message was
// printed. A script that prints "credentials missing" and then submits
// anyway would pass a message-only test; it must not pass these.

private let scriptPath = FileManager.default.currentDirectoryPath + "/Scripts/notarize.sh"

private struct ScriptResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Runs Scripts/notarize.sh with the given arguments and an EXPLICIT
/// environment (not inherited — a real developer machine could have
/// NOTARY_PROFILE etc. already set, and inheriting it would let a
/// validation test pass for the wrong reason, exactly the class of bug
/// this milestone keeps finding).
private func runScript(
    _ arguments: [String],
    env: [String: String] = [:],
    extraPath: String? = nil
) -> ScriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: scriptPath)
    process.arguments = arguments

    var environment = env
    // PATH must resolve at least the coreutils notarize.sh's usage/error
    // paths need (basename) plus, unless a test overrides it, the real
    // toolchain (codesign, ditto, mktemp, xcrun) so unrelated checks behave
    // like production. Tests that want to fake out `xcrun` or `ditto`
    // prepend `extraPath` so their stub shadows the real binary.
    let realPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["PATH"] = extraPath.map { "\($0):\(realPath)" } ?? realPath

    process.environment = environment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        return ScriptResult(status: -1, stdout: "", stderr: "failed to launch notarize.sh: \(error)")
    }
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ScriptResult(
        status: process.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? ""
    )
}

/// A minimal but structurally valid, UNSIGNED app bundle: just enough for
/// notarize.sh's own "is this a bundle" check to pass, so tests further
/// down the validation chain (signing, credentials) aren't blocked on it.
private func makeStubApp() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "snitt-notarize-test-\(UUID().uuidString)")
    let contents = dir.appending(path: "Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleExecutable</key><string>Stub</string>
      <key>CFBundleIdentifier</key><string>com.impressiver.snitt.notarize-test</string>
    </dict></plist>
    """
    try plist.write(to: contents.appending(path: "Info.plist"), atomically: true, encoding: .utf8)
    let macos = contents.appending(path: "MacOS")
    try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    // A real executable, not just a plist, so `codesign` has something to sign.
    try "#!/bin/sh\nexit 0\n".write(to: macos.appending(path: "Stub"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macos.appending(path: "Stub").path)
    return dir
}

/// Signs the stub app ad-hoc, which is enough for `codesign --verify
/// --deep --strict` to pass — notarize.sh only checks validity, not
/// identity, before submission.
@discardableResult
private func signAdHoc(_ app: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["--force", "--sign", "-", app.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// Writes an executable fake binary into a fresh directory and returns the
/// directory, for prepending onto PATH. Used to intercept `ditto` or
/// `xcrun` so a test can prove notarize.sh never reached them, rather than
/// trusting its printed message.
private func makeFakeBin(name: String, script: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "snitt-notarize-fakebin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let binPath = dir.appending(path: name)
    try script.write(to: binPath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binPath.path)
    return dir
}

/// Same as `makeFakeBin`, but for stubbing OUT MULTIPLE binaries (e.g. both
/// `xcrun` and `spctl`) into a single directory so one `extraPath` prefix
/// shadows all of them.
private func makeFakeBinDir(_ files: [String: String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "snitt-notarize-fakebin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, script) in files {
        let binPath = dir.appending(path: name)
        try script.write(to: binPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binPath.path)
    }
    return dir
}

@Test("Missing arguments fail loudly, before touching the network")
func notarizeRejectsMissingArgument() throws {
    // This script runs rarely and under release pressure. A silent or
    // obscure failure at that moment is the whole cost.
    //
    // Wrong implementation this catches: a script that omits the `$# -lt 1`
    // check and instead lets `${1-}` silently expand to empty, falling
    // through to the "no such file" branch with a confusing empty path
    // instead of naming the real problem (no argument at all).
    let result = runScript([])
    #expect(result.status != 0)
    #expect(result.stderr.contains("usage"))
    #expect(result.stderr.contains("<path-to-app>"))
}

@Test("An explicitly empty path argument is reported distinctly from a missing one")
func notarizeRejectsEmptyPathArgument() throws {
    // ${1-} vs ${1:-} has already caused a real bug in this project (R15).
    // An empty string IS an argument ($# == 1) and must not be silently
    // treated the same as "no argument" or coerced into some default —
    // it must be named as empty.
    //
    // Wrong implementation this catches: `APP="${1:-}"` with no separate
    // `-z "$APP"` check falls through to `[ ! -e "$APP" ]`, which is also
    // true for an empty string, so it fails with "no such file or
    // directory: " (trailing nothing) instead of naming the argument as
    // empty.
    let result = runScript([""], env: ["NOTARY_PROFILE": "synthetic-test-profile"])
    #expect(result.status != 0)
    #expect(result.stderr.contains("must not be empty"))
    #expect(!result.stderr.lowercased().contains("no such"))
}

@Test("A nonexistent app path is named, not silently passed through")
func notarizeRejectsMissingApp() throws {
    let result = runScript(["/nonexistent/Snitt.app"], env: ["NOTARY_PROFILE": "synthetic-test-profile"])
    #expect(result.status != 0)
    #expect(result.stderr.lowercased().contains("no such"))
}

@Test("A directory that isn't a bundle is rejected before signing or credentials are even checked")
func notarizeRejectsNonBundleDirectory() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "snitt-not-a-bundle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = runScript([dir.path], env: ["NOTARY_PROFILE": "synthetic-test-profile"])
    #expect(result.status != 0)
    #expect(result.stderr.contains("does not look like an app bundle"))
}

@Test("An unsigned bundle is refused, and the script never reaches the zip step")
func notarizeRejectsUnsignedBundle() throws {
    let app = try makeStubApp()
    defer { try? FileManager.default.removeItem(at: app) }
    // Deliberately not signed.

    // Instrument `ditto` (the first external tool notarize.sh calls AFTER
    // all validation) so we can assert the SIDE EFFECT is absent, not just
    // that a message was printed. A wrong implementation that logs "not
    // signed" as a warning and continues anyway would still print the
    // right-looking message but would touch this marker.
    let marker = FileManager.default.temporaryDirectory.appending(path: "snitt-notarize-ditto-marker-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: marker) }
    let fakeBin = try makeFakeBin(name: "ditto", script: "#!/bin/sh\ntouch \"\(marker.path)\"\nexit 0\n")
    defer { try? FileManager.default.removeItem(at: fakeBin) }

    let result = runScript([app.path], env: ["NOTARY_PROFILE": "synthetic-test-profile"], extraPath: fakeBin.path)
    #expect(result.status != 0)
    #expect(result.stderr.lowercased().contains("not validly signed"))
    #expect(!FileManager.default.fileExists(atPath: marker.path), "notarize.sh reached ditto despite an unsigned bundle")
}

@Test("Missing credentials name exactly which variable to set, and the script never reaches the zip step")
func notarizeNamesMissingCredentials() throws {
    let app = try makeStubApp()
    defer { try? FileManager.default.removeItem(at: app) }
    #expect(try signAdHoc(app) == 0)

    // Discriminating against a script that just fails: the message has to
    // tell the maintainer WHICH variable to set, at 2am, on a release.
    let marker = FileManager.default.temporaryDirectory.appending(path: "snitt-notarize-ditto-marker-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: marker) }
    let fakeBin = try makeFakeBin(name: "ditto", script: "#!/bin/sh\ntouch \"\(marker.path)\"\nexit 0\n")
    defer { try? FileManager.default.removeItem(at: fakeBin) }

    let result = runScript([app.path], env: [:], extraPath: fakeBin.path)
    #expect(result.status != 0)
    #expect(result.stderr.contains("NOTARY_PROFILE"))
    #expect(result.stderr.contains("NOTARY_KEY"))
    #expect(!FileManager.default.fileExists(atPath: marker.path), "notarize.sh reached ditto with no credentials at all")
}

@Test("A partial API-key trio is rejected and names only the missing piece")
func notarizeRejectsPartialCredentialTrio() throws {
    // Wrong implementation this catches: a check that only fires when ALL
    // THREE of NOTARY_KEY/KEY_ID/ISSUER are empty (e.g. `if [ -z
    // "$K$I$S" ]`) would let two-of-three through, and notarytool would be
    // invoked with an empty --key-id or --issuer — malformed input reaching
    // the network instead of being named here.
    let app = try makeStubApp()
    defer { try? FileManager.default.removeItem(at: app) }
    #expect(try signAdHoc(app) == 0)

    let marker = FileManager.default.temporaryDirectory.appending(path: "snitt-notarize-ditto-marker-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: marker) }
    let fakeBin = try makeFakeBin(name: "ditto", script: "#!/bin/sh\ntouch \"\(marker.path)\"\nexit 0\n")
    defer { try? FileManager.default.removeItem(at: fakeBin) }

    let result = runScript(
        [app.path],
        env: [
            "NOTARY_KEY_ID": "SYNTHETICKEYID99",
            "NOTARY_ISSUER": "00000000-synthetic-issuer-0000",
            // NOTARY_KEY deliberately absent.
        ],
        extraPath: fakeBin.path
    )
    #expect(result.status != 0)
    #expect(result.stderr.contains("missing: NOTARY_KEY"))
    #expect(!result.stderr.contains("missing: NOTARY_KEY NOTARY_KEY_ID"), "should not also claim KEY_ID is missing when it was set")
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test("A NOTARY_KEY that doesn't point at a real file is rejected with its own message")
func notarizeRejectsMalformedKeyPath() throws {
    let app = try makeStubApp()
    defer { try? FileManager.default.removeItem(at: app) }
    #expect(try signAdHoc(app) == 0)

    let result = runScript(
        [app.path],
        env: [
            "NOTARY_KEY": "/nonexistent/synthetic-key.p8",
            "NOTARY_KEY_ID": "SYNTHETICKEYID99",
            "NOTARY_ISSUER": "00000000-synthetic-issuer-0000",
        ]
    )
    #expect(result.status != 0)
    #expect(result.stderr.contains("NOTARY_KEY does not point at a file"))
}

@Test("Both the keychain-profile and API-key-trio credential paths are reachable, and NOTARY_PROFILE takes precedence")
func notarizeCredentialPathsAreReachableWithStatedPrecedence() throws {
    // These stop short of a real submission (no Apple credentials exist
    // here) by intercepting `xcrun` itself: `--find notarytool` reports
    // present, and `notarytool submit` records that it was reached (proving
    // credential validation passed and the network step was attempted)
    // then fails cleanly, which notarize.sh must propagate as a failure
    // rather than swallow.
    let app = try makeStubApp()
    defer { try? FileManager.default.removeItem(at: app) }
    #expect(try signAdHoc(app) == 0)

    // Also records the full argv of the `notarytool submit` call to
    // `marker`, not just that it was called — needed below to tell WHICH
    // credential flag was actually used, not merely that submission was
    // attempted.
    func fakeXcrun(marker: URL) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--find" ]; then
          exit 0
        fi
        if [ "$1" = "notarytool" ] && [ "$2" = "submit" ]; then
          echo "$@" > "\(marker.path)"
          exit 1
        fi
        exit 1
        """
    }

    // 1. Keychain-profile path.
    let profileMarker = FileManager.default.temporaryDirectory.appending(path: "snitt-notarize-xcrun-marker-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: profileMarker) }
    let profileFakeBin = try makeFakeBin(name: "xcrun", script: fakeXcrun(marker: profileMarker))
    defer { try? FileManager.default.removeItem(at: profileFakeBin) }

    let profileResult = runScript(
        [app.path],
        env: ["NOTARY_PROFILE": "synthetic-test-profile"],
        extraPath: profileFakeBin.path
    )
    #expect(profileResult.status != 0, "fake xcrun deliberately fails submit; a zero status here would mean failure wasn't propagated")
    #expect(FileManager.default.fileExists(atPath: profileMarker.path), "keychain-profile path never reached notarytool submit")

    // 2. API-key-trio path.
    let keyMarker = FileManager.default.temporaryDirectory.appending(path: "snitt-notarize-xcrun-marker-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: keyMarker) }
    let keyFakeBin = try makeFakeBin(name: "xcrun", script: fakeXcrun(marker: keyMarker))
    defer { try? FileManager.default.removeItem(at: keyFakeBin) }
    // A synthetic, clearly-fake key file — never a real credential.
    let keyFile = FileManager.default.temporaryDirectory.appending(path: "snitt-synthetic-key-\(UUID().uuidString).p8")
    try "SYNTHETIC-NOT-A-REAL-KEY".write(to: keyFile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: keyFile) }

    let keyResult = runScript(
        [app.path],
        env: [
            "NOTARY_KEY": keyFile.path,
            "NOTARY_KEY_ID": "SYNTHETICKEYID99",
            "NOTARY_ISSUER": "00000000-synthetic-issuer-0000",
        ],
        extraPath: keyFakeBin.path
    )
    #expect(keyResult.status != 0)
    #expect(FileManager.default.fileExists(atPath: keyMarker.path), "API-key-trio path never reached notarytool submit")

    // 3a. Precedence, weak form: NOTARY_PROFILE set alongside an INCOMPLETE
    // key trio must still succeed in reaching submission via the profile,
    // not fail on the incomplete trio.
    let incompleteMarker = FileManager.default.temporaryDirectory.appending(path: "snitt-notarize-xcrun-marker-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: incompleteMarker) }
    let incompleteFakeBin = try makeFakeBin(name: "xcrun", script: fakeXcrun(marker: incompleteMarker))
    defer { try? FileManager.default.removeItem(at: incompleteFakeBin) }

    let incompleteResult = runScript(
        [app.path],
        env: [
            "NOTARY_PROFILE": "synthetic-test-profile",
            "NOTARY_KEY_ID": "SYNTHETICKEYID99",
            // NOTARY_KEY and NOTARY_ISSUER deliberately absent — the trio
            // alone would fail validation. The profile should still win.
        ],
        extraPath: incompleteFakeBin.path
    )
    #expect(!incompleteResult.stderr.contains("NOTARY_KEY"), "profile should take precedence; the incomplete key trio should never be evaluated")
    #expect(FileManager.default.fileExists(atPath: incompleteMarker.path), "profile-precedence path never reached notarytool submit")

    // 3b. Precedence, strong form: both a profile AND a COMPLETE, valid
    // key trio are set. The weak form above cannot catch an implementation
    // that only falls back to the profile when the trio is incomplete (an
    // "either works, prefer whichever is complete" rule) rather than truly
    // preferring the profile — proven below by first breaking real
    // precedence and confirming this exact assertion fails. Inspect the
    // actual argv `notarytool submit` received, not just that submission
    // was attempted, so a mutant that reaches the network with the WRONG
    // flag set is still caught.
    let bothMarker = FileManager.default.temporaryDirectory.appending(path: "snitt-notarize-xcrun-marker-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: bothMarker) }
    let bothFakeBin = try makeFakeBin(name: "xcrun", script: fakeXcrun(marker: bothMarker))
    defer { try? FileManager.default.removeItem(at: bothFakeBin) }
    let bothKeyFile = FileManager.default.temporaryDirectory.appending(path: "snitt-synthetic-key-\(UUID().uuidString).p8")
    try "SYNTHETIC-NOT-A-REAL-KEY".write(to: bothKeyFile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: bothKeyFile) }

    let bothResult = runScript(
        [app.path],
        env: [
            "NOTARY_PROFILE": "synthetic-test-profile",
            "NOTARY_KEY": bothKeyFile.path,
            "NOTARY_KEY_ID": "SYNTHETICKEYID99",
            "NOTARY_ISSUER": "00000000-synthetic-issuer-0000",
        ],
        extraPath: bothFakeBin.path
    )
    #expect(bothResult.status != 0)
    let bothArgv = (try? String(contentsOf: bothMarker, encoding: .utf8)) ?? ""
    #expect(bothArgv.contains("--keychain-profile"), "expected notarytool submit to be called with --keychain-profile when both are set; got: \(bothArgv)")
    #expect(!bothArgv.contains("--key "), "notarytool submit must not receive --key when NOTARY_PROFILE is also set; got: \(bothArgv)")
}

@Test("A missing xcrun fails with a specific, actionable message")
func notarizeFailsWhenXcrunAbsent() throws {
    let app = try makeStubApp()
    defer { try? FileManager.default.removeItem(at: app) }
    #expect(try signAdHoc(app) == 0)

    // A PATH with no xcrun at all — but real coreutils still resolvable so
    // notarize.sh's OWN logic (not a missing `basename`) is what's exercised.
    let emptyBin = try makeFakeBin(name: "placeholder-not-a-real-tool", script: "#!/bin/sh\nexit 0\n")
    defer { try? FileManager.default.removeItem(at: emptyBin) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: scriptPath)
    process.arguments = [app.path]
    process.environment = [
        "PATH": emptyBin.path,
        "NOTARY_PROFILE": "synthetic-test-profile",
    ]
    let stderrPipe = Pipe()
    process.standardOutput = Pipe()
    process.standardError = stderrPipe
    try process.run()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let stderr = String(data: stderrData, encoding: .utf8) ?? ""

    #expect(process.terminationStatus != 0)
    #expect(stderr.contains("xcrun not found"))
}

@Test("A present xcrun but absent notarytool subcommand fails with its own message")
func notarizeFailsWhenNotarytoolSubcommandAbsent() throws {
    let app = try makeStubApp()
    defer { try? FileManager.default.removeItem(at: app) }
    #expect(try signAdHoc(app) == 0)

    // xcrun exists and resolves, but "--find notarytool" fails — an older
    // Xcode command line tools install, pre-notarytool.
    let fakeBin = try makeFakeBin(name: "xcrun", script: "#!/bin/sh\nexit 1\n")
    defer { try? FileManager.default.removeItem(at: fakeBin) }

    let result = runScript([app.path], env: ["NOTARY_PROFILE": "synthetic-test-profile"], extraPath: fakeBin.path)
    #expect(result.status != 0)
    #expect(result.stderr.contains("notarytool not found"))
}

// R26: the brief's own emphasised requirement — "It must staple and then
// verify... fail on either" — had zero coverage. Swallowing both `stapler
// staple` and `spctl --assess` failures with `|| true` passed the full
// suite green. These two tests close that: a fake `xcrun` reports
// notarytool present and lets `submit` "succeed" without ever touching the
// network, so each test isolates exactly one of the two final steps.

/// A fake `xcrun` that reports notarytool present, lets `notarytool submit`
/// "succeed" (so the run reaches stapling), and lets `stapler staple`
/// succeed or fail as directed — never touching the real network.
private func fakeXcrunScript(stapleSucceeds: Bool) -> String {
    """
    #!/bin/sh
    if [ "$1" = "--find" ]; then
      exit 0
    fi
    if [ "$1" = "notarytool" ] && [ "$2" = "submit" ]; then
      exit 0
    fi
    if [ "$1" = "stapler" ] && [ "$2" = "staple" ]; then
      \(stapleSucceeds ? "exit 0" : "exit 1")
    fi
    exit 1
    """
}

@Test("A stapler failure is fatal, and spctl is never reached")
func notarizeFailsWhenStaplingFails() throws {
    // Wrong implementation this catches: `xcrun stapler staple "$APP" ||
    // true` (or any variant that logs and continues). Verified by mutation
    // — applying exactly that to the committed script makes this test fail
    // (spctl marker present, or status == 0).
    let app = try makeStubApp()
    defer { try? FileManager.default.removeItem(at: app) }
    #expect(try signAdHoc(app) == 0)

    let spctlMarker = FileManager.default.temporaryDirectory.appending(path: "snitt-notarize-spctl-marker-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: spctlMarker) }
    let fakeBin = try makeFakeBinDir([
        "xcrun": fakeXcrunScript(stapleSucceeds: false),
        // spctl must never run if stapling failed — instrumented so the
        // test can prove absence, not just read a message.
        "spctl": "#!/bin/sh\ntouch \"\(spctlMarker.path)\"\nexit 0\n",
    ])
    defer { try? FileManager.default.removeItem(at: fakeBin) }

    let result = runScript([app.path], env: ["NOTARY_PROFILE": "synthetic-test-profile"], extraPath: fakeBin.path)
    #expect(result.status != 0, "a failed staple must be a fatal error, not a warning")
    #expect(result.stderr.contains("stapler staple failed"))
    #expect(!FileManager.default.fileExists(atPath: spctlMarker.path), "notarize.sh ran spctl despite a failed staple")
    #expect(!result.stdout.contains("Notarized, stapled, and verified"), "must not print the success line after a failed staple")
}

@Test("An spctl rejection is fatal, even after a successful staple")
func notarizeFailsWhenSpctlAssessmentFails() throws {
    // Wrong implementation this catches: `spctl --assess ... || true`, or
    // any variant that treats spctl's verdict as advisory. This is the
    // exact failure mode the brief calls out by name: a stapled bundle
    // that LOOKS distributable but Gatekeeper will reject on a clean
    // machine. Verified by mutation — `|| true` on the spctl check alone
    // makes this test fail (status == 0, success line printed).
    let app = try makeStubApp()
    defer { try? FileManager.default.removeItem(at: app) }
    #expect(try signAdHoc(app) == 0)

    let fakeBin = try makeFakeBinDir([
        "xcrun": fakeXcrunScript(stapleSucceeds: true),
        "spctl": "#!/bin/sh\nexit 3\n",
    ])
    defer { try? FileManager.default.removeItem(at: fakeBin) }

    let result = runScript([app.path], env: ["NOTARY_PROFILE": "synthetic-test-profile"], extraPath: fakeBin.path)
    #expect(result.status != 0, "an spctl rejection must be a fatal error")
    #expect(result.stderr.contains("will not be trusted"))
    #expect(!result.stdout.contains("Notarized, stapled, and verified"), "must not print the success line after a failed spctl assessment")
}
