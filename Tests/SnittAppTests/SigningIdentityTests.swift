// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation

// M5b release-identity task: Scripts/signing-identity.sh gained
// SNITT_SIGN_IDENTITY so a release build can select the real Developer ID
// instead of the self-signed local "Snitt Development" identity, without
// making that choice automatic just because a certificate exists.
//
// These tests run the REAL script against a fake `security` binary placed
// first on PATH, so the identity list it sees is controlled by the test
// rather than by whatever is actually installed in the machine's keychain
// (which varies — this repo's own CI/dev machines may or may not have a
// Developer ID installed at all). Only `security find-identity -p
// codesigning` is faked; the script calls nothing else.
//
// Explicit environment throughout (never inherited): a real developer
// machine could have SNITT_SIGN_IDENTITY exported from an earlier release
// build, and inheriting the ambient environment would let a test pass (or
// fail) for the wrong reason instead of the one line each test sets.

private struct ScriptResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func runSigningIdentity(env: [String: String], fakeIdentities: String) throws -> ScriptResult {
    let fakeBin = FileManager.default.temporaryDirectory.appending(path: "snitt-fake-security-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fakeBin) }

    let fakeSecurity = fakeBin.appending(path: "security")
    // Ignores its arguments entirely and prints a fixed identity list — the
    // script only ever calls `security find-identity -p codesigning`, so a
    // args-blind stub is sufficient and keeps the fixture simple.
    try """
    #!/bin/sh
    cat <<'IDENTITIES'
    \(fakeIdentities)
    IDENTITIES
    """.write(to: fakeSecurity, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSecurity.path)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "Scripts/signing-identity.sh")
    var environment = env
    environment["PATH"] = "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin"
    process.environment = environment
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ScriptResult(
        status: process.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? ""
    )
}

private let defaultDevIdentityLine = "  1) ABCDEF1234567890ABCDEF1234567890ABCDEF12 \"Snitt Development\""
private let devIDIdentityLine = "  2) 0011223344556677889900112233445566778899 \"Developer ID Application: impressiver LLC (TEGDRM8W7U)\""

@Test("Default (unset SNITT_SIGN_IDENTITY): unchanged behaviour, prints \"Snitt Development\" when installed")
func defaultUnsetPicksSnittDevelopment() throws {
    // Wrong implementation this catches: a change that makes the script
    // prefer a Developer ID whenever one is present in the identity list,
    // even with no override requested — the exact "automatic" behaviour
    // this task was told NOT to build.
    let result = try runSigningIdentity(
        env: [:],
        fakeIdentities: "\(defaultDevIdentityLine)\n\(devIDIdentityLine)\n2 identities found"
    )
    #expect(result.status == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "Snitt Development")
}

@Test("Default (unset SNITT_SIGN_IDENTITY), identity not installed: falls to the create-one instructions, not an override error")
func defaultUnsetMissingPrintsCreateInstructions() throws {
    let result = try runSigningIdentity(env: [:], fakeIdentities: "0 identities found")
    #expect(result.status != 0)
    #expect(result.stderr.contains("Create one ONCE"))
    #expect(!result.stderr.contains("SNITT_SIGN_IDENTITY"), "an unset override must never be blamed for a missing default identity")
}

@Test("SNITT_SIGN_IDENTITY set to an empty string is a hard error, never treated as \"use the default\"")
func emptyOverrideIsHardError() throws {
    // Wrong implementation this catches: `${SNITT_SIGN_IDENTITY:-Snitt
    // Development}` (or any other `:`-form default) — that form treats an
    // empty override exactly like an unset one and would silently print
    // "Snitt Development" here instead of failing.
    let result = try runSigningIdentity(
        env: ["SNITT_SIGN_IDENTITY": ""],
        fakeIdentities: "\(defaultDevIdentityLine)\n1 identity found"
    )
    #expect(result.status != 0)
    #expect(result.stdout.isEmpty, "an empty override must never fall through to printing the default identity")
    #expect(result.stderr.contains("set but empty"))
}

@Test("SNITT_SIGN_IDENTITY names an installed Developer ID: prints that exact identity")
func explicitOverrideFindsRequestedIdentity() throws {
    let requested = "Developer ID Application: impressiver LLC (TEGDRM8W7U)"
    let result = try runSigningIdentity(
        env: ["SNITT_SIGN_IDENTITY": requested],
        fakeIdentities: "\(defaultDevIdentityLine)\n\(devIDIdentityLine)\n2 identities found"
    )
    #expect(result.status == 0, "stderr: \(result.stderr)")
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == requested)
}

@Test("SNITT_SIGN_IDENTITY names an identity that isn't installed: fails loudly naming both the request and what's available")
func explicitOverrideMissingFailsLoudly() throws {
    // Wrong implementation this catches: falling back to "Snitt
    // Development" (or to ad-hoc) when the requested identity can't be
    // found — the exact silent-wrong-certificate failure this mechanism
    // exists to prevent.
    let requested = "Developer ID Application: Some Other Team (NOTREAL123)"
    let result = try runSigningIdentity(
        env: ["SNITT_SIGN_IDENTITY": requested],
        fakeIdentities: "\(defaultDevIdentityLine)\n\(devIDIdentityLine)\n2 identities found"
    )
    #expect(result.status != 0)
    #expect(result.stdout.isEmpty, "a missing override must never fall through to printing any identity at all")
    #expect(result.stderr.contains(requested), "error must name what was actually asked for")
    #expect(result.stderr.contains("Snitt Development"), "error must list what's actually available")
    #expect(result.stderr.contains("Developer ID Application: impressiver LLC (TEGDRM8W7U)"), "error must list what's actually available")
    #expect(!result.stderr.contains("Create one ONCE"), "an override failure must not print the self-signed-cert creation instructions — those are for the unset-default path only")
}
