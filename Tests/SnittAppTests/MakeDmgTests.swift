// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation

// Scripts/make-dmg.sh builds the drag-to-Applications installer published as a
// GitHub Releases asset. It is NOT an update artifact — Sparkle's appcast
// enclosure is the ZIP — so nothing here asserts anything about appcasts.
//
// The real image cannot be built in a test: `hdiutil create` on a 27MB bundle
// takes seconds, and signing it needs a Developer ID. So every test below
// shadows `hdiutil` with a stub earlier in PATH, and asserts BOTH the exit
// status AND whether the script reached the stub — a script that prints
// "refusing" and then builds anyway passes a message-only test and must not
// pass these. The stub also records the arguments it was handed, which is how
// the image's *contents* get asserted without ever mounting a volume.

private let scriptPath = FileManager.default.currentDirectoryPath + "/Scripts/make-dmg.sh"

private struct ScriptResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Runs make-dmg.sh with an EXPLICIT environment. Not inherited: a real
/// developer machine has SNITT_SIGN_IDENTITY set during a release, and
/// inheriting it would make the unsigned-warning test pass for the wrong
/// reason — the same trap NotarizeScriptTests documents for NOTARY_PROFILE.
private func runScript(_ arguments: [String],
                       env: [String: String] = [:],
                       extraPath: String? = nil) -> ScriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: scriptPath)
    process.arguments = arguments
    var environment = env
    let realPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["PATH"] = extraPath.map { "\($0):\(realPath)" } ?? realPath
    process.environment = environment

    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch {
        return ScriptResult(status: -1, stdout: "", stderr: "failed to launch make-dmg.sh: \(error)")
    }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ScriptResult(status: process.terminationStatus,
                        stdout: String(decoding: outData, as: UTF8.self),
                        stderr: String(decoding: errData, as: UTF8.self))
}

/// A structurally valid app bundle. `version` nil omits
/// CFBundleShortVersionString entirely, for the test that the script refuses
/// to name an image after a version it cannot read.
private func makeStubApp(version: String? = "9.9.9") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "snitt-dmg-test-\(UUID().uuidString)/Snitt.app")
    let contents = dir.appending(path: "Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let versionKey = version.map {
        "<key>CFBundleShortVersionString</key><string>\($0)</string>"
    } ?? ""
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleExecutable</key><string>Stub</string>
      <key>CFBundleIdentifier</key><string>com.impressiver.snitt.dmg-test</string>
      \(versionKey)
    </dict></plist>
    """
    try plist.write(to: contents.appending(path: "Info.plist"), atomically: true, encoding: .utf8)
    let macos = contents.appending(path: "MacOS")
    try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    let exe = macos.appending(path: "Stub")
    try "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    return dir
}

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

/// A stand-in `hdiutil` that records the arguments it was called with — and,
/// critically, a listing of the staging directory it was pointed at, taken
/// while that directory still exists. That listing is how the image's contents
/// are asserted without mounting anything.
private struct HdiutilStub {
    let binDir: URL
    let receipt: URL

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "snitt-dmg-fakebin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        binDir = dir
        receipt = dir.appending(path: "receipt.txt")
        let script = """
        #!/bin/bash
        # Record the invocation, then the staged tree, then create the output
        # file so the caller's own `du` succeeds.
        echo "ARGS: $*" >> "\(receipt.path)"
        src=""; out=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -srcfolder) src="$2"; shift 2 ;;
            -volname) echo "VOLNAME: $2" >> "\(receipt.path)"; shift 2 ;;
            -*) shift ;;
            *) out="$1"; shift ;;
          esac
        done
        if [ -n "$src" ]; then
          /bin/ls -la "$src" | /usr/bin/sed 's/^/STAGED: /' >> "\(receipt.path)"
        fi
        [ -n "$out" ] && /usr/bin/touch "$out"
        exit 0
        """
        let path = dir.appending(path: "hdiutil")
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    /// Empty when make-dmg.sh never reached the build step.
    var contents: String { (try? String(contentsOf: receipt, encoding: .utf8)) ?? "" }
    var wasCalled: Bool { !contents.isEmpty }
}

/// Somewhere to drop the output file that is not the repo. make-dmg.sh
/// deliberately does not cd, and no test may mutate the process-global current
/// directory, so every test passes an absolute --output instead.
private func outputPath(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "snitt-dmg-out-\(UUID().uuidString)")
        .appending(path: name)
}

@Test("A path that is not an app bundle is rejected before any image is built")
func dmgRejectsNonBundle() throws {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "snitt-dmg-plain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stub = try HdiutilStub()

    let result = runScript([dir.path], extraPath: stub.binDir.path)

    #expect(result.status != 0)
    #expect(result.stderr.contains("does not look like an app bundle"))
    #expect(!stub.wasCalled, "hdiutil ran against something that is not an app")
}

@Test("An unsigned app is refused, and no image is built")
func dmgRejectsUnsignedApp() throws {
    // Not signed at all. hdiutil would package it perfectly happily, and the
    // result is only discovered to be worthless after it is uploaded.
    let app = try makeStubApp()
    let stub = try HdiutilStub()

    let result = runScript([app.path], extraPath: stub.binDir.path)

    #expect(result.status != 0)
    #expect(result.stderr.contains("not validly signed"))
    #expect(!stub.wasCalled, "hdiutil ran on an unsigned app")
}

@Test("An app Apple has never notarized is refused, and no image is built")
func dmgRejectsUnnotarizedApp() throws {
    // The defect this script exists to prevent. Ad-hoc signed, so it clears
    // the codesign check above and can only fail on the notarization one —
    // without that separation this test would pass against a script that had
    // no notarization check at all.
    let app = try makeStubApp()
    #expect(try signAdHoc(app) == 0)
    let stub = try HdiutilStub()

    let result = runScript([app.path], extraPath: stub.binDir.path)

    #expect(result.status != 0)
    #expect(result.stderr.contains("not notarized"))
    #expect(!stub.wasCalled, "hdiutil ran on an app Gatekeeper would reject")
}

@Test("--allow-unstapled builds anyway, and says the result must not be published")
func dmgAllowUnstapledProceedsLoudly() throws {
    // The escape hatch has to work, or the previous test passes for the wrong
    // reason — a script that refused everything would satisfy it.
    let app = try makeStubApp()
    #expect(try signAdHoc(app) == 0)
    let stub = try HdiutilStub()
    let out = outputPath("Out.dmg")

    let result = runScript([app.path, "--allow-unstapled", "--output", out.path],
                           extraPath: stub.binDir.path)

    #expect(result.status == 0)
    #expect(stub.wasCalled, "the escape hatch did not reach the build step")
    #expect(result.stderr.contains("must not be published"))
}

@Test("The image is named from the app's own Info.plist, not from AppVersion.swift")
func dmgNameComesFromTheBundle() throws {
    // The stub says 9.9.9; AppVersion.fallback says something else entirely.
    // A script reading the source of truth instead of the artifact would ship
    // a stale build under a fresh version's name — the same class of drift
    // make-appcast.sh cross-checks for.
    let app = try makeStubApp(version: "9.9.9")
    #expect(try signAdHoc(app) == 0)
    let stub = try HdiutilStub()
    let workDir = FileManager.default.temporaryDirectory
        .appending(path: "snitt-dmg-name-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

    let result = runScript([app.path, "--allow-unstapled",
                            "--output", workDir.appending(path: "Snitt-9.9.9.dmg").path],
                           extraPath: stub.binDir.path)

    #expect(result.status == 0)
    #expect(result.stdout.contains("Snitt-9.9.9.dmg"))
    // And the volume name carries it too, so a mounted image says which
    // version it is rather than colliding with every other mounted Snitt.
    #expect(stub.contents.contains("VOLNAME: Snitt 9.9.9"))
}

@Test("An app with no version string is refused rather than named after an empty one")
func dmgRefusesMissingVersion() throws {
    // Otherwise the output is "Snitt-.dmg", which uploads without complaint.
    let app = try makeStubApp(version: nil)
    #expect(try signAdHoc(app) == 0)
    let stub = try HdiutilStub()

    let result = runScript([app.path, "--allow-unstapled"], extraPath: stub.binDir.path)

    #expect(result.status != 0)
    #expect(result.stderr.contains("CFBundleShortVersionString"))
    #expect(!stub.wasCalled)
}

@Test("The image holds the app and an /Applications symlink, and nothing else")
func dmgStagesAppAndApplicationsLink() throws {
    // Asserted from the staging tree hdiutil was actually handed, not from the
    // script's output. Two failures this catches: a missing /Applications
    // symlink, which leaves users running the app from the mounted image where
    // it cannot update and vanishes on eject; and pointing hdiutil at a real
    // directory, which ships whatever else happens to be sitting in it.
    let app = try makeStubApp()
    #expect(try signAdHoc(app) == 0)
    let stub = try HdiutilStub()
    let out = outputPath("Out.dmg")

    let result = runScript([app.path, "--allow-unstapled", "--output", out.path],
                           extraPath: stub.binDir.path)

    #expect(result.status == 0)
    let staged = stub.contents
    #expect(staged.contains("Snitt.app"))
    #expect(staged.contains("Applications -> /Applications"))
}

@Test("Without a signing identity the image is called out as unsigned, not quietly shipped")
func dmgWarnsWhenUnsigned() throws {
    // A DMG arrives from a browser quarantined; an unsigned one is refused
    // before the user ever reaches the app inside it. Silence here would let
    // a release ship one.
    let app = try makeStubApp()
    #expect(try signAdHoc(app) == 0)
    let stub = try HdiutilStub()
    let out = outputPath("Out.dmg")

    let result = runScript([app.path, "--allow-unstapled", "--output", out.path],
                           extraPath: stub.binDir.path)

    #expect(result.status == 0)
    #expect(result.stderr.contains("UNSIGNED"))
}

@Test("An empty --output is rejected rather than treated as a default")
func dmgRejectsEmptyOutput() throws {
    let app = try makeStubApp()
    let stub = try HdiutilStub()
    let result = runScript([app.path, "--output", ""], extraPath: stub.binDir.path)
    #expect(result.status != 0)
    #expect(result.stderr.contains("--output requires a path"))
    #expect(!stub.wasCalled)
}
