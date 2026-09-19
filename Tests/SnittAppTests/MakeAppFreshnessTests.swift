// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation

// `make-app.sh` used to hardcode where `swift build` writes:
// `.build/apple/Products/Debug` for a multi-arch build. A toolchain update
// moved the real output to `.build/out/Products/Debug` and LEFT THE OLD
// DIRECTORY IN PLACE, holding the binary from the last build that used it.
//
// The check that was supposed to catch this asked `[ -f "$PRODUCT_DIR/$x" ]`
// — the file was right there, so it passed. Every universal build from then
// on copied a weeks-old app into the bundle, and universal is tied to
// SNITT_SIGN_IDENTITY, so that means every RELEASE. v0.6.0 and v0.6.1 both
// shipped an app binary frozen at the last build that used the old path,
// while local development builds were correct and every test passed.
//
// Nothing failed. It surfaced only when a shipped feature appeared to have
// "disappeared" from the released app.
//
// The property under test is FRESHNESS, not existence. That distinction is
// the entire bug: existence is the adjacent property, and asserting it is
// what let this ship twice.
/// A disposable path for `make-app.sh`'s output.
///
/// Every test in this file drives the REAL script, and the script removes
/// `$APP` from an EXIT trap whenever it exits non-zero — which is what these
/// tests assert. With the default path that deleted the developer's own
/// `build/Snitt.app`, in the repo root, while other suites were reading it.
/// Pointing `SNITT_APP_PATH` somewhere disposable keeps the script under test
/// unchanged and stops it reaching outside its own test.
private func disposableAppPath() -> String {
    FileManager.default.temporaryDirectory
        .appending(path: "snitt-makeapp-\(UUID().uuidString)")
        .appending(path: "Snitt.app").path
}

@Suite(.serialized)
struct MakeAppFreshnessTests {
    /// A `swift` that reports a product directory of our choosing and builds
    /// nothing, so a test can hand `make-app.sh` a directory whose contents
    /// are older than the source tree.
    private func makeStubSwift(reporting productDir: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "snitt-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let swift = dir.appending(path: "swift")
        try """
            #!/bin/bash
            for a in "$@"; do
              if [ "$a" = "--show-bin-path" ]; then echo "\(productDir)"; exit 0; fi
            done
            exit 0
            """.write(to: swift, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: swift.path)
        return dir
    }

    /// Products that exist but predate the sources.
    private func makeStaleProducts() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "snitt-stale-products-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["SnittApp", "snitt-cli", "snitt-mcp"] {
            let f = dir.appending(path: name)
            try "#!/bin/sh\n".write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755,
                 .modificationDate: Date(timeIntervalSince1970: 1_756_684_800)],
                ofItemAtPath: f.path)
        }
        return dir
    }

    @Test("A product older than the sources is refused, not copied into the bundle")
    func staleProductIsRefused() throws {
        let products = try makeStaleProducts()
        defer { try? FileManager.default.removeItem(at: products) }
        let stubDir = try makeStubSwift(reporting: products.path)
        defer { try? FileManager.default.removeItem(at: stubDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [FileManager.default.currentDirectoryPath + "/Scripts/make-app.sh"]
        process.environment = [
            "PATH": "\(stubDir.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "SNITT_UNIVERSAL": "1",
            "HOME": NSHomeDirectory(),
            "SNITT_APP_PATH": disposableAppPath(),
        ]
        let err = Pipe(), out = Pipe()
        process.standardError = err
        process.standardOutput = out
        try process.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        _ = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stderr = String(decoding: errData, as: UTF8.self)

        // The pre-fix behaviour was exit 0 and a stale app in build/Snitt.app.
        #expect(process.terminationStatus != 0,
                "a stale product must be a hard failure, not a silent release")
        #expect(stderr.contains("is OLDER than"),
                "the refusal must say WHICH file is stale")
    }

    /// A release must never be a debug build.
    ///
    /// Every release up to and including v0.6.1 shipped `-c debug`:
    /// unoptimised, with debug assertions live and the `#if DEBUG` code that
    /// exists for previews and test seams compiled in. Nobody chose that; it
    /// was the only configuration the script knew how to build.
    ///
    /// Asserted on the CONFIGURATION THE SCRIPT ASKS FOR, by watching the
    /// `swift` it invokes, rather than on a string in the file. A stub that
    /// records its own arguments is the only way to see what was actually
    /// requested, and the requested configuration is what decides both the
    /// optimisation level and which product directory gets copied.
    @Test("A signed build asks swift for release, and an unsigned one does not")
    func signedBuildUsesReleaseConfiguration() throws {
        func configurationRequested(signed: Bool) throws -> String {
            let dir = FileManager.default.temporaryDirectory
                .appending(path: "snitt-config-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let log = dir.appending(path: "args.log")
            let swift = dir.appending(path: "swift")
            try """
                #!/bin/bash
                echo "$@" >> "\(log.path)"
                for a in "$@"; do
                  if [ "$a" = "--show-bin-path" ]; then echo "\(dir.path)"; exit 0; fi
                done
                exit 0
                """.write(to: swift, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: swift.path)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [FileManager.default.currentDirectoryPath + "/Scripts/make-app.sh"]
            var env = ["PATH": "\(dir.path):/usr/bin:/bin:/usr/sbin:/sbin",
                       "HOME": NSHomeDirectory(),
                       "SNITT_APP_PATH": disposableAppPath()]
            // A fake identity: this test is about the CONFIGURATION that
            // choice selects, and it never reaches signing.
            if signed { env["SNITT_SIGN_IDENTITY"] = "Developer ID Application: test" }
            process.environment = env
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            _ = out.fileHandleForReading.readDataToEndOfFile()
            _ = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        }

        let signed = try configurationRequested(signed: true)
        #expect(signed.contains("-c release"),
                "a signed build must ask for release")
        #expect(!signed.contains("-c debug"),
                "a signed build asked for debug somewhere")

        let unsigned = try configurationRequested(signed: false)
        #expect(unsigned.contains("-c debug"),
                "a development build should stay debug for build speed")
    }
}

@Suite(.serialized)
struct MakeAppOutputIsolation {
    /// The regression this file caused, pinned so it cannot return quietly.
    ///
    /// `make-app.sh` removes `$APP` from an EXIT trap on any non-zero exit,
    /// and the tests above exist to force non-zero exits. Before
    /// `SNITT_APP_PATH`, that trap reached the repo's own `build/Snitt.app`,
    /// because the script cd's to the repo root no matter where it is invoked
    /// from. The damage was invisible twice over: CI and fresh worktrees have
    /// no bundle to destroy, and `BundleLayoutTests` SKIPS when one is absent
    /// while still reporting the run passed.
    @Test("A failing run deletes only the path it was given")
    func failureCleansOnlyItsOwnOutput() throws {
        // A stand-in for the developer's real bundle, in a directory the
        // script is NOT told about. Discriminates against reading
        // SNITT_APP_PATH for the build but leaving the trap on the default:
        // that passes any test which only checks where the app was written.
        let bystander = FileManager.default.temporaryDirectory
            .appending(path: "snitt-bystander-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bystander, withIntermediateDirectories: true)
        let sentinel = bystander.appending(path: "Snitt.app")
        try FileManager.default.createDirectory(at: sentinel, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bystander) }

        let target = disposableAppPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // No stubbed `swift` on PATH, so the script fails early and the EXIT
        // trap is what runs. Failing is the point: this asserts what cleanup
        // touches, not what a build produces.
        process.arguments = [FileManager.default.currentDirectoryPath + "/Scripts/make-app.sh"]
        process.environment = [
            "PATH": "/nonexistent-bin",
            "HOME": NSHomeDirectory(),
            "SNITT_APP_PATH": target,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus != 0, "the run must fail, or the trap never fires")
        #expect(FileManager.default.fileExists(atPath: sentinel.path),
                "a failing make-app.sh deleted a bundle it was never pointed at")
    }

    @Test("The script reads the override rather than hardcoding its output")
    func overrideIsHonoured() throws {
        // Reads the assignment out of the script rather than restating it, so
        // reverting to a hardcoded path fails here instead of silently
        // re-arming the trap against the repo root.
        let source = try String(
            contentsOfFile: FileManager.default.currentDirectoryPath + "/Scripts/make-app.sh",
            encoding: .utf8)
        let line = try #require(
            source.split(separator: "\n").first { $0.hasPrefix("APP=") },
            "make-app.sh no longer assigns APP")
        #expect(line.contains("SNITT_APP_PATH"),
                "APP must stay overridable or the tests here clobber build/Snitt.app again: \(line)")
        #expect(line.contains("build/Snitt.app"),
                "the default must remain build/Snitt.app for production: \(line)")
    }
}
