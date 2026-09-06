import Testing
import Foundation

// R27 (Task 4 review): the N8 fail-open fix in
// Scripts/lib/sign-app-with-workaround.sh shipped with no regression test.
// N8 was: `if [ "$("$SCRIPT_DIR/needs-teamless-workaround.sh" ...)" = "yes" ]`
// swallows the inner script's exit status under `set -e` — if the decision
// script can't even run, `$(...)` silently produces an empty string,
// `[ "" = "yes" ]` is false, and the ELSE branch runs: no entitlement, exit
// 0, "Real Team ID" printed without ever asking the question. These tests
// pin the fix (capture the decision and its exit status separately) so a
// future refactor can't reintroduce it silently.
//
// R28 (same review): SNITT_FAKE_TEAM_IDENTIFIER_LINE must refuse to
// override once the signature it's layered onto already carries a genuine
// Team ID. Pinned here too, since it lives in the same script and the same
// risk class (a security-relevant decision failing in the permissive
// direction).
//
// All tests run the REAL script against a temp COPY of Scripts/lib, so a
// test can chmod -x or replace the decision script without touching the
// production files other tests (and other engineers) rely on.

private struct ScriptResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func run(_ executable: URL, _ arguments: [String], env: [String: String] = [:]) -> ScriptResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    var environment = env
    if environment["PATH"] == nil {
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    }
    process.environment = environment
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    do {
        try process.run()
    } catch {
        return ScriptResult(status: -1, stdout: "", stderr: "failed to launch \(executable.path): \(error)")
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

/// Copies Scripts/lib into a fresh temp directory so a test can mutate the
/// decision script (chmod, replace contents) without touching the real one.
private func copyScriptsLib() throws -> URL {
    let src = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Scripts/lib")
    let dst = FileManager.default.temporaryDirectory.appending(path: "snitt-scripts-lib-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: src, to: dst)
    return dst
}

/// A minimal, real, signable file — sign-app-with-workaround.sh calls
/// `codesign` directly on it, so it needs to be a real file, not just a path.
private func makeSignableStub() throws -> URL {
    let path = FileManager.default.temporaryDirectory.appending(path: "snitt-signable-stub-\(UUID().uuidString)")
    try "#!/bin/sh\nexit 0\n".write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    return path
}

@Test("N8 regression: an unexecutable decision script fails loudly, not silently as Real Team ID")
func signAppFailsLoudlyWhenDecisionScriptCannotRun() throws {
    let lib = try copyScriptsLib()
    defer { try? FileManager.default.removeItem(at: lib) }
    let stub = try makeSignableStub()
    defer { try? FileManager.default.removeItem(at: stub) }

    let decisionScript = lib.appending(path: "needs-teamless-workaround.sh")
    #expect(FileManager.default.fileExists(atPath: decisionScript.path))
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: decisionScript.path)

    let signScript = lib.appending(path: "sign-app-with-workaround.sh")
    let result = run(signScript, [stub.path, "-"])

    // Pre-fix behaviour (reproduced during review at 2efce2b): exit 0,
    // "Real Team ID (TeamIdentifier=not set)" printed, no entitlement
    // question ever asked. That is the wrong implementation this pins.
    #expect(result.status != 0, "an unrunnable decision script must be a hard failure, not a silent Real-Team-ID answer")
    #expect(result.stderr.contains("refusing to guess whether the workaround is needed"))
    #expect(!result.stdout.contains("Real Team ID"), "must not report a Real Team ID verdict it never actually computed")
}

@Test("An unexpected (non yes/no) decision answer fails loudly instead of silently taking a branch")
func signAppRejectsUnexpectedDecisionAnswer() throws {
    let lib = try copyScriptsLib()
    defer { try? FileManager.default.removeItem(at: lib) }
    let stub = try makeSignableStub()
    defer { try? FileManager.default.removeItem(at: stub) }

    let decisionScript = lib.appending(path: "needs-teamless-workaround.sh")
    try "#!/bin/sh\necho maybe\nexit 0\n".write(to: decisionScript, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: decisionScript.path)

    let signScript = lib.appending(path: "sign-app-with-workaround.sh")
    let result = run(signScript, [stub.path, "-"])

    #expect(result.status != 0)
    #expect(result.stderr.contains("unexpected answer"))
    #expect(!result.stdout.contains("Real Team ID"))
    #expect(!result.stderr.contains("adding disable-library-validation"))
}

@Test("R28: SNITT_FAKE_TEAM_IDENTIFIER_LINE is refused once the real signature already carries a genuine Team ID")
func signAppRefusesFakeOverrideAgainstGenuineTeamID() throws {
    let lib = try copyScriptsLib()
    defer { try? FileManager.default.removeItem(at: lib) }
    let stub = try makeSignableStub()
    defer { try? FileManager.default.removeItem(at: stub) }

    // Fake `codesign` ahead of the real one: `--force ...` (the actual
    // signing call) is a no-op success, and `-dvv` reports a GENUINE,
    // non-"not set" TeamIdentifier — simulating what a real Developer ID
    // build would read back, without needing one to exist in this repo.
    let fakeBin = FileManager.default.temporaryDirectory.appending(path: "snitt-fake-codesign-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fakeBin) }
    let fakeCodesign = fakeBin.appending(path: "codesign")
    try """
    #!/bin/sh
    case "$1" in
      --force) exit 0 ;;
      -dvv) echo "TeamIdentifier=REALTEAM123SYNTHETIC" >&2; exit 0 ;;
      *) exit 1 ;;
    esac
    """.write(to: fakeCodesign, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodesign.path)

    let signScript = lib.appending(path: "sign-app-with-workaround.sh")
    let result = run(
        signScript,
        [stub.path, "-"],
        env: [
            "SNITT_FAKE_TEAM_IDENTIFIER_LINE": "TeamIdentifier=FAKELINE999",
            "PATH": "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin",
        ]
    )

    #expect(result.status != 0, "the override must not be allowed to mask a genuine Team ID")
    #expect(result.stderr.contains("refusing to override a real identity"))
    #expect(!result.stdout.contains("FAKELINE999"), "the fake line must never be acted on once a genuine identity is present")
}

@Test("Without the override, a genuine Team ID still takes the no-workaround branch normally")
func signAppHonoursGenuineTeamIDWithoutOverride() throws {
    // Control for the refusal above: gating must not block the NORMAL
    // genuine-identity path when no override is even set.
    let lib = try copyScriptsLib()
    defer { try? FileManager.default.removeItem(at: lib) }
    let stub = try makeSignableStub()
    defer { try? FileManager.default.removeItem(at: stub) }

    let fakeBin = FileManager.default.temporaryDirectory.appending(path: "snitt-fake-codesign-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fakeBin) }
    let fakeCodesign = fakeBin.appending(path: "codesign")
    try """
    #!/bin/sh
    case "$1" in
      --force) exit 0 ;;
      -dvv) echo "TeamIdentifier=REALTEAM123SYNTHETIC" >&2; exit 0 ;;
      *) exit 1 ;;
    esac
    """.write(to: fakeCodesign, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodesign.path)

    let signScript = lib.appending(path: "sign-app-with-workaround.sh")
    let result = run(
        signScript,
        [stub.path, "-"],
        env: ["PATH": "\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin"]
    )

    #expect(result.status == 0, "a genuine Team ID with no override set must proceed normally: \(result.stderr)")
    #expect(result.stdout.contains("Real Team ID"))
}
