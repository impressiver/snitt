// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation

// `release.sh` used to finish by checking that the release's assets EXISTED
// and were non-empty. v0.6.0 and v0.6.1 both passed that check while shipping
// an app binary built weeks earlier (#173), because a stale file is present
// and non-empty like any other.
//
// `verify_published_app` opens the published zip instead. These tests drive it
// with a doctored archive, because a verification step that cannot fail is
// indistinguishable from one that is not running.
@Suite(.serialized)
struct PublishedArtifactTests {
    /// A directory of stubs plus a published zip containing whatever
    /// `Info.plist` values a test asks for.
    private func stage(shortVersion: String, buildNumber: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "snitt-published-\(UUID().uuidString)")
        let bin = root.appending(path: "bin")
        let app = root.appending(path: "stage/Snitt.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"),
                                         to: app.appending(path: "Snitt"))
        try """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleShortVersionString</key><string>\(shortVersion)</string>
            <key>CFBundleVersion</key><string>\(buildNumber)</string>
            </dict></plist>
            """.write(to: root.appending(path: "stage/Snitt.app/Contents/Info.plist"),
                      atomically: true, encoding: .utf8)

        let zip = root.appending(path: "Snitt-\(releasableVersion).zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent",
                           root.appending(path: "stage/Snitt.app").path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()

        let gh = bin.appending(path: "gh")
        try """
            #!/bin/bash
            if [ "$1" = "release" ] && [ "$2" = "view" ]; then
              printf 'Snitt-\(releasableVersion).zip\\t1234\\nappcast.xml\\t1008\\nSnitt-\(releasableVersion).dmg\\t5678\\n'
              exit 0
            fi
            if [ "$1" = "release" ] && [ "$2" = "download" ]; then
              for ((i=1;i<=$#;i++)); do
                [ "${!i}" = "--dir" ] && j=$((i+1)) && d="${!j}"
              done
              cp "\(zip.path)" "$d/"
              exit 0
            fi
            exit 0
            """.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)

        // The tag being verified does not exist in this repo, so the real
        // `git rev-list` would fail and the build-number check would skip
        // itself — passing the test for the wrong reason. Stubbed to a fixed
        // count so the comparison actually runs.
        let git = bin.appending(path: "git")
        try """
            #!/bin/bash
            if [ "$1" = "rev-list" ]; then echo "\(taggedCommitCount)"; exit 0; fi
            exit 0
            """.write(to: git, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)
        return root
    }

    /// The version this repo's tags actually carry, so the stubs line up with
    /// whatever `--verify` is asked about.
    private var releasableVersion: String { "9.9.9" }

    /// What the stubbed `git rev-list` reports for the tag.
    private var taggedCommitCount: String { "203" }

    private func runVerify(stubs: URL) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [FileManager.default.currentDirectoryPath + "/Scripts/release.sh",
                             "--verify", releasableVersion]
        process.environment = [
            "PATH": "\(stubs.appending(path: "bin").path):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
        ]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try? process.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: o, as: UTF8.self) + String(decoding: e, as: UTF8.self))
    }

    @Test("A published app whose version disagrees with the release is refused")
    func wrongVersionIsRefused() throws {
        // The wrong implementation this kills: checking the asset's NAME,
        // which carries the version and therefore always agrees with itself.
        let stubs = try stage(shortVersion: "0.0.1", buildNumber: "1")
        defer { try? FileManager.default.removeItem(at: stubs) }
        let result = runVerify(stubs: stubs)
        #expect(result.status != 0, "a mismatched version must fail the release")
        #expect(result.output.contains("calls itself '0.0.1'"),
                "the refusal must name what the artifact actually claims")
    }

    @Test("A published app whose build number does not match the tag is refused")
    func wrongBuildNumberIsRefused() throws {
        // This is the property that ties the ARTIFACT to the TAG. Compared
        // against the tag's own commit count, never HEAD's: by the time this
        // runs, step 10 has moved HEAD to the next -dev, and comparing to
        // HEAD would accept whatever happened to be shipped.
        let stubs = try stage(shortVersion: releasableVersion, buildNumber: "999999")
        defer { try? FileManager.default.removeItem(at: stubs) }
        let result = runVerify(stubs: stubs)
        #expect(result.status != 0, "an artifact that does not match the tag must fail")
        #expect(result.output.contains("does not match the tag")
                    || result.output.contains("build 999999"),
                "the refusal must say the artifact and the tag disagree")
    }
}
