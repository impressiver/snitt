// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation

/// The Homebrew cask, checked against the things it has to agree with.
///
/// A cask is three facts about a release — its version, its hash and its URL —
/// written down somewhere the release does not look. That is the same shape as
/// the export destinations' stale-limit problem, and it fails the same way:
/// silently, for somebody else, some time after the mistake. `release.sh`
/// rewrites the version and hash on every release; these tests cover the parts
/// it does not touch, which are the parts a human edits.
struct HomebrewCaskTests {

    private var cask: String {
        let path = FileManager.default.currentDirectoryPath + "/Casks/snitt.rb"
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    @Test("The cask exists and names the app Homebrew will install")
    func caskIsPresent() {
        #expect(!cask.isEmpty, "Casks/snitt.rb is missing")
        #expect(cask.contains("cask \"snitt\""))
        #expect(cask.contains("app \"Snitt.app\""))
    }

    @Test("The download URL matches the asset the release script actually uploads")
    func urlMatchesTheReleaseArtifact() throws {
        // The drift that produces a 404 for everyone at once. `release.sh`
        // builds `Snitt-$VERSION.zip` and tags `v$VERSION`; the cask has to
        // spell both the same way, and nothing else checks that they do.
        let script = try String(
            contentsOfFile: FileManager.default.currentDirectoryPath + "/Scripts/release.sh",
            encoding: .utf8)
        #expect(script.contains("ZIP=\"Snitt-$VERSION.zip\""),
                "release.sh no longer names the zip Snitt-<version>.zip — update the cask URL")
        #expect(script.contains("TAG=\"v$VERSION\""),
                "release.sh no longer tags v<version> — update the cask URL")
        #expect(cask.contains("releases/download/v#{version}/Snitt-#{version}.zip"),
                "the cask URL does not match the released asset name")
    }

    @Test("The cask installs a released version, never a development one")
    func versionIsReleasable() throws {
        // `main` carries a `-dev` marketing version between releases, and a
        // cask pointing at one would 404: no such tag was ever pushed. The
        // release script writes this field, so this guards a hand edit that
        // copied the version out of AppVersion.swift.
        let line = try #require(cask.split(separator: "\n")
            .first { $0.contains("version \"") })
        #expect(!line.contains("-dev"), "the cask points at a development version: \(line)")
        let digits = line.filter { $0.isNumber || $0 == "." }
        #expect(digits.split(separator: ".").count == 3, "expected a three-part version: \(line)")
    }

    @Test("The cask's macOS requirement matches the package's own floor")
    func minimumMacOSAgrees() throws {
        // A cask that installs on a system the app refuses to launch on turns
        // a clear "requires macOS 26" into a crash on first open, which reads
        // as a broken app rather than an unmet requirement.
        let package = try String(
            contentsOfFile: FileManager.default.currentDirectoryPath + "/Package.swift",
            encoding: .utf8)
        #expect(package.contains(".macOS(.v26)"),
                "the deployment target moved — update depends_on in the cask")
        #expect(cask.contains("depends_on macos:"), "the cask states no macOS requirement")
        #expect(cask.contains("tahoe"), "the cask's macOS requirement is not macOS 26 (Tahoe)")

        // The string-comparison form is deprecated, and Homebrew says so on
        // every `brew info` and twice on every `brew install`:
        //
        //   Warning: Calling string comparison format for `depends_on macos:`
        //   is deprecated! Use `depends_on macos: :tahoe` instead.
        //
        // Only an install shows that. No test read it, `brew` was never run
        // against the cask in CI, and the warning named this tap as the thing
        // to report it to — so the first person to run the documented install
        // line was told the cask is out of date by Homebrew itself.
        //
        // The bare symbol means the same thing: "Top-level `depends_on macos:`
        // marks a cask as macOS-only and declares the minimum compatible macOS
        // release" (Cask Cookbook). Worth checking rather than assuming,
        // because the wrong reading installs only on macOS 26 and refuses
        // every release after it.
        // Read the STANZAS, not the file. This is the third text guard today
        // to fail on the comment that explains it, and `Casks/snitt.rb` warned
        // about the shape from the other side before any of them: "a mutation
        // anchor that also appears in prose mutates the prose and leaves the
        // stanza intact". A guard that cannot tell an explanation from the
        // thing it explains gets deleted the first time it cries wolf.
        let stanzas = cask.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        #expect(!stanzas.contains("\">= :"),
                "the deprecated string-comparison form of depends_on is back")
    }

    @Test("The cask does not claim to install a CLI it cannot find")
    func noBinaryStanza() {
        // `Contents/MacOS` holds only Snitt and Sparkle.framework — the `snitt`
        // CLI is not inside the bundle. A `binary` stanza pointing into it
        // would make every install print a broken-symlink warning, and would
        // look from the outside like the CLI had been installed.
        #expect(!cask.contains("binary \""),
                "the cask links a binary; the CLI is not inside the app bundle")
    }

    @Test("The release script updates the cask, so it cannot go stale")
    func releaseKeepsTheCaskCurrent() throws {
        // The structural half. Without this the cask is a hand-maintained copy
        // of two facts about the latest release, and the failure is silent:
        // it keeps installing the PREVIOUS version for everyone, and nothing
        // reports it because the download still works.
        let script = try String(
            contentsOfFile: FileManager.default.currentDirectoryPath + "/Scripts/release.sh",
            encoding: .utf8)
        // The PATH, not just the name of the variable. `CASK_SOURCE=` is
        // still present when the value is empty, and an empty value makes the
        // whole update a no-op — the `-f` guard simply never fires and the
        // release succeeds with a stale cask. Verified against that mutant.
        #expect(script.contains("CASK_SOURCE=\"Casks/snitt.rb\""),
                "release.sh does not point at the cask file")
        #expect(script.contains("shasum -a 256 \"$ZIP\""),
                "release.sh does not hash the zip it just published")
        // Committed with the version bump, not left dirty in the tree for
        // somebody to find and wonder about.
        #expect(script.contains("git add \"$CASK_SOURCE\""),
                "the updated cask is never staged, so the change is lost")
    }

    @Test("Homebrew is told the app updates itself")
    func sparkleIsDeclared() {
        // Without `auto_updates`, `brew upgrade` reinstalls the version
        // Homebrew knows over a newer one Sparkle already installed — a
        // downgrade the user never asked for and would struggle to explain.
        #expect(cask.contains("auto_updates true"))
    }
}
