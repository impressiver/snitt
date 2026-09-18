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
}
