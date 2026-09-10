// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation

// Scripts/release.sh publishes a release and then checks what landed.
//
// The step it exists for is the upload. The release runbook had seven
// commands and an eighth step that was a paragraph asking a human to remember
// three files — and a release missing its DMG looks exactly like a release.
// The person who finds out is somebody arriving at the Releases page with no
// copy of Snitt installed and nothing to click.
//
// So the test that matters here is `uploadListIsTheVerificationList`. Every
// other test in this file checks a refusal; that one checks the property the
// whole script is for, and it does it by running the real publish path with
// `--dry-run` and reading back the arguments the `gh release create` call was
// built with — not by grepping the source for a filename, which is the
// adjacent-property version of this test and would pass against a script that
// uploaded three files and verified two.
//
// Same shadow-the-tool-on-PATH technique as `MakeDmgTests`, for the same
// reason: the real path needs a Developer ID, Apple's servers, and a tag push.
private let scriptPath = FileManager.default.currentDirectoryPath + "/Scripts/release.sh"

private struct ScriptResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var output: String { stdout + stderr }
}

/// Runs release.sh with an EXPLICIT environment. Never inherited: a
/// maintainer's shell has `SNITT_SIGN_IDENTITY` set during a release, and
/// inheriting it would make the missing-identity test pass for the wrong
/// reason.
private func runScript(_ arguments: [String],
                       env: [String: String] = [:],
                       extraPath: String? = nil) -> ScriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [scriptPath] + arguments
    var environment = env
    let realPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["PATH"] = extraPath.map { "\($0):\(realPath)" } ?? realPath
    process.environment = environment

    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch {
        return ScriptResult(status: -1, stdout: "", stderr: "launch failed: \(error)")
    }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ScriptResult(status: process.terminationStatus,
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData, as: UTF8.self))
}

/// A directory of stub executables, placed earlier in PATH than the real
/// tools. Everything the preflight consults is stubbed to the state a real
/// release would be in, so a test can drive the publish path without a
/// keychain, a network, or a clean tree.
private func makeStubs(gitBranch: String = "main",
                       gitDirty: Bool = false,
                       tagExists: Bool = false,
                       releaseExists: Bool = false) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "snitt-release-stubs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    func write(_ name: String, _ body: String) throws {
        let url = dir.appending(path: name)
        try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
    }

    try write("git", """
        case "$1 $2" in
          "rev-parse --abbrev-ref") echo "\(gitBranch)" ;;
          "rev-parse v"*)           exit \(tagExists ? 0 : 1) ;;
          "status --porcelain")     \(gitDirty ? "echo ' M Sources/x.swift'" : "true") ;;
          *)                        true ;;
        esac
        """)
    try write("gh", """
        case "$1 $2" in
          "release view") exit \(releaseExists ? 0 : 1) ;;
          *)              true ;;
        esac
        """)
    try write("lipo", "echo 'x86_64 arm64'")
    // `Scripts/signing-identity.sh` greps this for the requested name. The
    // stub reports the identity the tests ask for as installed — the tests
    // are about release.sh's checks, not about a real keychain.
    try write("security", """
        echo '  1) ABC "Developer ID Application: test"'
        """)
    return dir
}

@Suite(.serialized)
struct ReleaseScriptTests {

    @Test("The required assets include the DMG, not just the update artifacts")
    func assetsIncludeTheInstaller() {
        // The zip and the appcast are what Sparkle needs; the DMG is what a
        // person with no copy of Snitt needs. A release script written from
        // Sparkle's point of view produces exactly the first two and looks
        // complete.
        let result = runScript(["--assets", "1.2.3"])
        #expect(result.status == 0)
        let assets = result.stdout.split(separator: "\n").map(String.init)
        #expect(assets == ["Snitt-1.2.3.zip", "appcast.xml", "Snitt-1.2.3.dmg"])
    }

    @Test("The upload list and the verification list are the same list")
    func uploadListIsTheVerificationList() throws {
        // The invariant the script is built around. Two lists is how a fourth
        // artifact gets added to the upload and never enrolled in the check —
        // or, as happened here in prose form, how the check never existed at
        // all. Driven through the real publish path so it asserts what the
        // script DOES, not what it says.
        let stubs = try makeStubs()
        defer { try? FileManager.default.removeItem(at: stubs) }
        let version = declaredVersion()
        let result = runScript([version, "--dry-run"],
                               env: ["SNITT_SIGN_IDENTITY": "Developer ID Application: test",
                                     "NOTARY_PROFILE": "snitt"],
                               extraPath: stubs.path)
        #expect(result.status == 0, "\(result.output)")

        let createLine = result.output.split(separator: "\n")
            .first { $0.contains("gh") && $0.contains("release") && $0.contains("create") }
        let create = try #require(createLine.map(String.init),
                                  "no gh release create in:\n\(result.output)")
        for asset in ["Snitt-\(version).zip", "appcast.xml", "Snitt-\(version).dmg"] {
            #expect(create.contains(asset), "create call omits \(asset): \(create)")
        }
        // And the verification step ran on the same release.
        #expect(result.output.contains("Verify what actually landed"))
    }

    @Test("A version that disagrees with AppVersion.fallback is refused")
    func versionMustMatchTheBinary() throws {
        // Sparkle compares the appcast against the INSTALLED app's
        // CFBundleShortVersionString, which make-app.sh takes from
        // AppVersion.fallback. A tag and a binary that disagree produce
        // "updates sometimes don't appear", with no error anywhere.
        let stubs = try makeStubs()
        defer { try? FileManager.default.removeItem(at: stubs) }
        let result = runScript(["99.98.97", "--dry-run"],
                               env: ["SNITT_SIGN_IDENTITY": "Developer ID Application: test"],
                               extraPath: stubs.path)
        #expect(result.status != 0)
        #expect(result.stderr.contains("AppVersion.fallback"))
        // And it stopped BEFORE building — a script that printed the warning
        // and carried on passes a message-only assertion.
        #expect(!result.output.contains("1. Build"))
    }

    @Test("Releasing without a Developer ID is refused")
    func signingIdentityIsRequired() throws {
        // Without it make-app.sh signs with the local self-signed identity
        // and builds native-only. Both produce an app that runs perfectly on
        // this machine and is rejected on every other one.
        let stubs = try makeStubs()
        defer { try? FileManager.default.removeItem(at: stubs) }
        let result = runScript([declaredVersion(), "--dry-run"], extraPath: stubs.path)
        #expect(result.status != 0)
        #expect(result.stderr.contains("SNITT_SIGN_IDENTITY"))
        #expect(!result.output.contains("1. Build"))
    }

    @Test("Missing notarization credentials stop the release before the build")
    func notaryCredentialsAreCheckedInPreflight() throws {
        // The regression this test exists for: the 0.3.0 attempt spent a full
        // universal build and a deep codesign verify before `notarize.sh`
        // reported it had no credentials. A preflight that catches the signing
        // identity and not the notary credential fails at exactly the point
        // where failing is most expensive.
        //
        // So `!contains("1. Build")` is the assertion that matters here, not
        // the exit status — the old script also exited non-zero, just three
        // minutes later.
        let stubs = try makeStubs()
        defer { try? FileManager.default.removeItem(at: stubs) }
        let result = runScript([declaredVersion(), "--dry-run"],
                               env: ["SNITT_SIGN_IDENTITY": "Developer ID Application: test"],
                               extraPath: stubs.path)
        #expect(result.status != 0)
        #expect(result.stderr.contains("NOTARY_PROFILE") || result.stderr.contains("NOTARY_KEY"))
        #expect(!result.output.contains("1. Build"),
                "preflight let the build run without notarization credentials")
    }

    @Test("A partial API-key credential is refused, naming what is missing")
    func partialApiKeyIsRefused() throws {
        // Two of three set is worse than none: it looks configured. This is
        // the shape `notarize.sh` already refuses, moved to where it costs
        // nothing.
        let stubs = try makeStubs()
        defer { try? FileManager.default.removeItem(at: stubs) }
        let result = runScript([declaredVersion(), "--dry-run"],
                               env: ["SNITT_SIGN_IDENTITY": "Developer ID Application: test",
                                     "NOTARY_KEY": "/tmp/nonexistent.p8",
                                     "NOTARY_KEY_ID": "ABCD1234"],
                               extraPath: stubs.path)
        #expect(result.status != 0)
        #expect(result.stderr.contains("NOTARY_ISSUER"))
        #expect(!result.output.contains("1. Build"))
    }

    @Test("An identity that is not in the keychain is refused before the build")
    func unknownSigningIdentityIsRefused() throws {
        // Delegated to `Scripts/signing-identity.sh`, which is the one place
        // that decides what a valid identity is. Before this, release.sh only
        // checked the variable was non-empty, so a typo'd identity name got
        // caught by codesign — after the universal build.
        let stubs = try makeStubs()
        defer { try? FileManager.default.removeItem(at: stubs) }
        let result = runScript([declaredVersion(), "--dry-run"],
                               env: ["SNITT_SIGN_IDENTITY": "Developer ID Application: typo",
                                     "NOTARY_PROFILE": "snitt"],
                               extraPath: stubs.path)
        #expect(result.status != 0)
        #expect(!result.output.contains("1. Build"))
    }

    @Test("An API key whose file is gone is refused, not discovered later")
    func unreadableKeyFileIsRefused() throws {
        // The stale-credential case: a path that used to resolve. It fails
        // identically to having no credential at all — after the build, from
        // inside notarytool.
        let stubs = try makeStubs()
        defer { try? FileManager.default.removeItem(at: stubs) }
        let result = runScript([declaredVersion(), "--dry-run"],
                               env: ["SNITT_SIGN_IDENTITY": "Developer ID Application: test",
                                     "NOTARY_KEY": "/tmp/definitely-not-here-\(UUID().uuidString).p8",
                                     "NOTARY_KEY_ID": "ABCD1234",
                                     "NOTARY_ISSUER": "11111111-2222-3333-4444-555555555555"],
                               extraPath: stubs.path)
        #expect(result.status != 0)
        #expect(result.stderr.contains("does not point at a file"))
        #expect(!result.output.contains("1. Build"))
    }

    @Test("A keychain profile alone is enough to proceed")
    func keychainProfileSatisfiesPreflight() throws {
        // The other half. A preflight that demanded the API-key trio
        // unconditionally would block the credential path `notarize.sh`
        // actually prefers.
        let stubs = try makeStubs()
        defer { try? FileManager.default.removeItem(at: stubs) }
        let result = runScript([declaredVersion(), "--dry-run"],
                               env: ["SNITT_SIGN_IDENTITY": "Developer ID Application: test",
                                     "NOTARY_PROFILE": "snitt"],
                               extraPath: stubs.path)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("keychain profile 'snitt'"))
    }

    @Test("A dirty tree, a feature branch, or a used tag each stop the release")
    func preflightRefusesAnUnreleasableState() throws {
        // One test, three states, because they are one requirement: the tag
        // must name a commit that is on the default branch and is exactly
        // what shipped. Asserted together so a script that checked only the
        // first cannot pass by satisfying the easiest one.
        let cases: [(String, URL)] = [
            ("dirty", try makeStubs(gitDirty: true)),
            ("branch", try makeStubs(gitBranch: "feat/something")),
            ("tag", try makeStubs(tagExists: true)),
        ]
        defer { for (_, dir) in cases { try? FileManager.default.removeItem(at: dir) } }

        for (name, stubs) in cases {
            let result = runScript([declaredVersion(), "--dry-run"],
                                   env: ["SNITT_SIGN_IDENTITY": "Developer ID Application: test"],
                                   extraPath: stubs.path)
            #expect(result.status != 0, "\(name) state was allowed to release")
            #expect(!result.output.contains("1. Build"),
                    "\(name) state printed a refusal and built anyway")
        }
    }

    @Test("A malformed version is refused before anything runs")
    func versionShapeIsChecked() {
        // `release.sh main` would otherwise produce Snitt-main.dmg and a tag
        // called vmain.
        for bad in ["main", "v1.2.3", "1.2", ""] {
            let result = runScript(bad.isEmpty ? [] : [bad])
            #expect(result.status != 0, "'\(bad)' was accepted as a version")
        }
    }

    @Test("Verify mode reports a release that is missing its installer")
    func verifyModeCatchesAMissingAsset() throws {
        // v0.1.0 shipped before the DMG existed and genuinely lacks one, so
        // this runs against a real, permanent example rather than a mock —
        // and it is the exact shape of the failure the script exists to make
        // impossible from now on.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "snitt-release-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gh = dir.appending(path: "gh")
        // A stub, not the network: this test must not need credentials or a
        // reachable github.com to run. The payload is v0.1.0's real asset
        // list, zip and appcast and no DMG.
        try """
            #!/bin/bash
            printf '%s\\t%s\\n' 'Snitt-0.1.0.zip' 3268499 'appcast.xml' 1012
            """.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: gh.path)

        let result = runScript(["--verify", "0.1.0"], extraPath: dir.path)
        #expect(result.status != 0)
        #expect(result.stderr.contains("MISSING"))
        #expect(result.stderr.contains("Snitt-0.1.0.dmg"))
    }

    @Test("Verify mode passes a release that has everything")
    func verifyModeAcceptsACompleteRelease() throws {
        // The other half. A verifier that reported MISSING unconditionally
        // would pass the test above.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "snitt-release-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gh = dir.appending(path: "gh")
        try """
            #!/bin/bash
            printf '%s\\t%s\\n' 'Snitt-0.2.0.zip' 8388063 'appcast.xml' 1012 \\
                                'Snitt-0.2.0.dmg' 10275411
            """.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: gh.path)

        let result = runScript(["--verify", "0.2.0"], extraPath: dir.path)
        #expect(result.status == 0, "\(result.output)")
        #expect(result.stdout.contains("every required asset"))
    }

    @Test("A zero-byte asset counts as missing")
    func emptyAssetsAreNotAccepted() throws {
        // What a failed upload leaves behind, and indistinguishable from a
        // successful one in the web UI's file list.
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "snitt-release-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gh = dir.appending(path: "gh")
        try """
            #!/bin/bash
            printf '%s\\t%s\\n' 'Snitt-0.2.0.zip' 8388063 'appcast.xml' 1012 \\
                                'Snitt-0.2.0.dmg' 0
            """.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: gh.path)

        let result = runScript(["--verify", "0.2.0"], extraPath: dir.path)
        #expect(result.status != 0)
        #expect(result.stderr.contains("EMPTY"))
    }
}

/// Whatever `AppVersion.fallback` says right now. Read from the file rather
/// than imported, so this suite keeps testing the script's own comparison
/// instead of agreeing with it by construction — and so a version bump does
/// not break the tests.
private func declaredVersion() -> String {
    let source = FileManager.default.currentDirectoryPath
        + "/Sources/SnittDocument/AppVersion.swift"
    guard let text = try? String(contentsOfFile: source, encoding: .utf8),
          let line = text.split(separator: "\n").first(where: {
              $0.contains("public static let fallback")
          }),
          let start = line.firstIndex(of: "\""),
          let end = line.lastIndex(of: "\""), start < end
    else { return "0.0.0" }
    return String(line[line.index(after: start)..<end])
}
