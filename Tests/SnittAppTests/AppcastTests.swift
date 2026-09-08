import Testing
import Foundation
import Darwin
import Security
import Sparkle

// Task 5: Scripts/make-appcast.sh generates the Sparkle appcast item for
// one release. GitHub Releases is the host (the maintainer's decision) and
// nothing secret enters this repo (the maintainer's other decision): the
// EdDSA private key never appears here, in a fixture, or in an example —
// only a plainly synthetic signature string ("abc123", matching Task 4's
// "REALTEAM123SYNTHETIC" precedent) or, where a REAL signature matters (to
// exercise Sparkle's own crypto), an ephemeral keypair generated fresh in
// a temp directory for the duration of one test and never written to the
// login Keychain.
//
// The sharpest trap named for this task: asserting the generated document
// *contains a string* rather than that the *consumer* (Sparkle) accepts
// it. Two tests below go further than substring checks:
//   - `sparkleParsesTheGeneratedFeed` drives a REAL `SPUUpdater` against a
//     REAL local HTTP server serving this script's output, and inspects
//     the `SUAppcastItem` Sparkle's own XML parser produced — not a
//     hand-rolled XML assertion.
//   - `theSignatureIsCryptographicallyValid` uses Sparkle's own
//     `sign_update --verify` (the same EdDSA implementation Sparkle uses
//     at install time) to check the emitted `sparkle:edSignature` against
//     the exact archive bytes it claims to cover, and confirms a tampered
//     archive or signature is REJECTED — not merely that a string is
//     present.
//
// What is NOT exercised here, and why: a full download-and-install cycle
// needs a code-signed, notarized app and a real update session; that is
// Definition-of-Done item 5, a manual step, not a unit test.

private let scriptPath = FileManager.default.currentDirectoryPath + "/Scripts/make-appcast.sh"
private let signUpdatePath = FileManager.default.currentDirectoryPath
    + "/.build/artifacts/sparkle/Sparkle/bin/sign_update"
// R4's standard, matching `BundleLayoutTests`' `appIsBuilt`/`appBundleSkipReason`:
// a condition trait, not a hard failure, when an environment-dependent
// prerequisite is missing. `theSignatureIsCryptographicallyValid` used to
// `Issue.record` and return here instead — effectively unreachable in
// practice, since Sparkle's SPM `binaryTarget` is always fetched on
// resolve, but the wrong shape for the one case where it isn't (a resolve
// that hasn't happened yet), which should skip, not fail.
private let signUpdateIsAvailable = FileManager.default.isExecutableFile(atPath: signUpdatePath)
private let signUpdateSkipReason: Comment =
    "sign_update not found — Sparkle SPM artifacts not resolved; run `swift package resolve` first"

private struct ScriptResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Runs Scripts/make-appcast.sh with the given arguments and an EXPLICIT
/// environment (not inherited) — a developer shell could have
/// SPARKLE_SIGNATURE already exported, and inheriting it would let a
/// "refuses when unsigned" test pass for the wrong reason.
private func runScript(_ arguments: [String], env: [String: String] = [:]) -> ScriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: scriptPath)
    process.arguments = arguments

    var environment = env
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    process.environment = environment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        return ScriptResult(status: -1, stdout: "", stderr: "failed to launch make-appcast.sh: \(error)")
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

/// Writes `byteCount` bytes of deterministic (non-zero) content to a fresh
/// temp file and returns its path. A real byte count, not an empty file —
/// so the enclosure `length` test below can't pass by coincidence against
/// a zero-length fixture.
private func makeFixtureArchive(byteCount: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("snitt-appcast-fixture-\(UUID().uuidString).zip")
    let content = Data(repeating: 0x41, count: byteCount)
    try content.write(to: url)
    return url
}

@Test("An appcast item carries version, URL and signature")
func appcastItemIsComplete() throws {
    let zip = try makeFixtureArchive(byteCount: 14)
    defer { try? FileManager.default.removeItem(at: zip) }

    let out = runScript(
        ["1.2.0", zip.path, "https://example.test/S.zip"],
        env: ["SPARKLE_SIGNATURE": "abc123"]
    )
    #expect(out.status == 0)
    #expect(out.stdout.contains("sparkle:shortVersionString=\"1.2.0\""))
    #expect(out.stdout.contains("https://example.test/S.zip"))
    #expect(out.stdout.contains("abc123"))
}

@Test("An unsigned item is refused, not emitted")
func unsignedAppcastIsRefused() throws {
    // This script refuses to EMIT an unsigned item at all, so the
    // install-time rejection this guards against is never actually
    // reached in the branch's current configuration: with no
    // SUPublicEDKey in the shipped plist (see Scripts/make-app.sh),
    // Sparkle never reads sparkle:edSignature and so never rejects on it
    // either way — see Scripts/make-appcast.sh's "CURRENT STATE" note and
    // docs/superpowers/notes/release-runbook.md. The reasoning below is
    // this script's OWN rationale for refusing early rather than leaving
    // Sparkle's client-side rejection (real once a key exists) as the
    // only guard: failing here costs a release; failing there would cost
    // the user's trust.
    let zip = try makeFixtureArchive(byteCount: 14)
    defer { try? FileManager.default.removeItem(at: zip) }

    let out = runScript(["1.2.0", zip.path, "https://example.test/S.zip"], env: [:])
    #expect(out.status != 0)
    #expect(out.stderr.contains("SPARKLE_SIGNATURE"))
    // Not merely a non-zero status: NO partial/half-written appcast may
    // reach stdout either. A script that prints the whole document and
    // THEN exits non-zero would pass a status-only check but still leaves
    // a document a careless caller could redirect to a file and publish.
    #expect(out.stdout.isEmpty)
}

@Test("A signature shaped like sign_update's un-'-p' output is refused, not emitted")
func fullSignUpdateOutputPastedAsSignatureIsRefused() throws {
    // R47 (fix-wave-rereview.md): `sign_update` WITHOUT `-p` prints the
    // whole `sparkle:edSignature="…" length="…"` attribute pair, not a
    // bare signature. Before this test's corresponding fix, pasting that
    // straight into [signature] produced a nested, quote-escaped garbage
    // attribute this script emitted without complaint. With a real
    // SUPublicEDKey now configured, every install would fail signature
    // verification against that garbage. Verified this fails
    // against the wrong implementation it exists to catch: temporarily
    // removed the `case … esac` shape check from make-appcast.sh and
    // re-ran — this test failed because the script exited 0 and emitted
    // the malformed attribute verbatim; restoring the check passed again.
    let zip = try makeFixtureArchive(byteCount: 14)
    defer { try? FileManager.default.removeItem(at: zip) }

    let wrongInput = "sparkle:edSignature=\"AbCdEf123==\" length=\"4096\""
    let out = runScript(["1.2.0", zip.path, "https://example.test/S.zip", wrongInput], env: [:])

    #expect(out.status != 0)
    #expect(out.stderr.contains("-p"), "the error should point the maintainer at sign_update -p: \(out.stderr)")
    // Same discipline as unsignedAppcastIsRefused: no partial document may
    // reach stdout, and the malformed attribute must never appear anywhere
    // in the output this script produced.
    #expect(out.stdout.isEmpty)
    #expect(!out.stdout.contains("sparkle:edSignature=\"sparkle:edSignature"))
}

@Test("A genuine bare EdDSA signature is still accepted")
func genuineBareSignatureIsAccepted() throws {
    // The shape check above must not be so broad it rejects real, valid
    // signatures — a base64 string legitimately contains letters, digits,
    // '+', '/', and trailing '=' padding, none of which trip the refusal.
    let zip = try makeFixtureArchive(byteCount: 14)
    defer { try? FileManager.default.removeItem(at: zip) }

    let realShapedSignature = "AbCdEf123456+/=="
    let out = runScript(["1.2.0", zip.path, "https://example.test/S.zip", realShapedSignature], env: [:])

    #expect(out.status == 0, "a well-formed bare signature must be accepted: \(out.stderr)")
    #expect(out.stdout.contains("sparkle:edSignature=\"\(realShapedSignature)\""))
}

@Test("Missing arguments and empty-string arguments are distinct failures")
func missingVersusEmptyArgumentsAreDistinguished() throws {
    let zip = try makeFixtureArchive(byteCount: 14)
    defer { try? FileManager.default.removeItem(at: zip) }

    // No arguments at all.
    let missing = runScript([])
    #expect(missing.status != 0)
    #expect(missing.stderr.contains("missing required arguments"))

    // An explicit empty version is a different, more specific complaint
    // than "missing" — R15 already burned this project once on exactly
    // this collapse.
    let emptyVersion = runScript(["", zip.path, "https://example.test/S.zip"], env: ["SPARKLE_SIGNATURE": "abc123"])
    #expect(emptyVersion.status != 0)
    #expect(emptyVersion.stderr.contains("<version>"))
    #expect(!emptyVersion.stderr.contains("missing required arguments"))

    let emptyURL = runScript(["1.2.0", zip.path, ""], env: ["SPARKLE_SIGNATURE": "abc123"])
    #expect(emptyURL.status != 0)
    #expect(emptyURL.stderr.contains("<release-url>"))
}

@Test("A nonexistent zip is refused, not silently given a zero length")
func nonexistentZipIsRefused() throws {
    let out = runScript(
        ["1.2.0", "/tmp/does-not-exist-\(UUID().uuidString).zip", "https://example.test/S.zip"],
        env: ["SPARKLE_SIGNATURE": "abc123"]
    )
    #expect(out.status != 0)
    #expect(out.stderr.contains("no such file"))
    #expect(out.stdout.isEmpty)
}

@Test("A directory given as the zip path is refused")
func directoryAsZipIsRefused() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("snitt-appcast-dir-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let out = runScript(["1.2.0", dir.path, "https://example.test/S.zip"], env: ["SPARKLE_SIGNATURE": "abc123"])
    #expect(out.status != 0)
    #expect(out.stdout.isEmpty)
}

@Test("The enclosure length is the archive's real byte count, not a placeholder")
func enclosureLengthMatchesRealArchiveSize() throws {
    // A deliberately unusual, non-round number: a wrong implementation
    // that hardcodes a length, or that miscounts (e.g. `wc -l` instead of
    // a byte count), cannot coincidentally match this by accident the way
    // it might match a "nice" number like 1024.
    let byteCount = 987_321
    let zip = try makeFixtureArchive(byteCount: byteCount)
    defer { try? FileManager.default.removeItem(at: zip) }

    let out = runScript(["9.9.9", zip.path, "https://example.test/S.zip"], env: ["SPARKLE_SIGNATURE": "sig"])
    #expect(out.status == 0)

    let document = try XMLDocument(xmlString: out.stdout, options: [])
    let enclosures = try document.nodes(forXPath: "//enclosure")
    let enclosure = try #require(enclosures.first as? XMLElement)
    let lengthValue = try #require(enclosure.attribute(forName: "length")?.stringValue)
    #expect(lengthValue == String(byteCount))
}

@Test("An explicit signature argument takes precedence over SPARKLE_SIGNATURE")
func explicitSignatureArgumentWinsOverEnvironment() throws {
    let zip = try makeFixtureArchive(byteCount: 14)
    defer { try? FileManager.default.removeItem(at: zip) }

    let out = runScript(
        ["1.2.0", zip.path, "https://example.test/S.zip", "arg-signature"],
        env: ["SPARKLE_SIGNATURE": "env-signature"]
    )
    #expect(out.status == 0)
    #expect(out.stdout.contains("arg-signature"))
    #expect(!out.stdout.contains("env-signature"))
}

@Test("The generated feed is well-formed XML with a single complete item")
func generatedFeedIsWellFormedXML() throws {
    let zip = try makeFixtureArchive(byteCount: 42)
    defer { try? FileManager.default.removeItem(at: zip) }

    let out = runScript(["3.4.5", zip.path, "https://example.test/S.zip"], env: ["SPARKLE_SIGNATURE": "xyz"])
    #expect(out.status == 0)

    // Parses as XML at all — not just "contains substrings that look like
    // tags". A malformed document (unescaped `&`, mismatched tags) fails
    // right here.
    let document = try XMLDocument(xmlString: out.stdout, options: [])
    let items = try document.nodes(forXPath: "/rss/channel/item")
    #expect(items.count == 1)

    let enclosures = try document.nodes(forXPath: "/rss/channel/item/enclosure")
    let enclosure = try #require(enclosures.first as? XMLElement)
    #expect(enclosure.attribute(forName: "url")?.stringValue == "https://example.test/S.zip")
    #expect(enclosure.attribute(forName: "sparkle:version")?.stringValue == "3.4.5")
    #expect(enclosure.attribute(forName: "sparkle:shortVersionString")?.stringValue == "3.4.5")
    #expect(enclosure.attribute(forName: "sparkle:edSignature")?.stringValue == "xyz")
}

// MARK: - The feed and the app must provably meet (R31, task-5-review.md)
//
// Before this section, `Scripts/make-app.sh`'s `SUFeedURL` and
// `make-appcast.sh`'s output agreed only by the maintainer remembering to
// type `> appcast.xml` — nothing failed if they drifted, which is exactly
// the silent-no-op class this task was warned about. `--output` plus the
// tests below pin the two together: an asset uploaded under any name
// other than `SUFeedURL`'s own basename is now something the SCRIPT
// itself refuses to produce, and a future edit to `SUFeedURL` that isn't
// matched here fails a test instead of silently drifting.

/// Reads `SUFeedURL`'s value straight out of `Scripts/make-app.sh`'s
/// Info.plist heredoc — the actual file the real build uses, not a copy
/// of the string — so this test breaks the moment that file's value
/// changes without a matching update here.
private func extractSUFeedURLFromMakeAppScript() throws -> String {
    let path = FileManager.default.currentDirectoryPath + "/Scripts/make-app.sh"
    let contents = try String(contentsOfFile: path, encoding: .utf8)
    let pattern = #"<key>SUFeedURL</key>\s*<string>([^<]+)</string>"#
    let regex = try NSRegularExpression(pattern: pattern)
    let range = NSRange(contents.startIndex..., in: contents)
    guard let match = regex.firstMatch(in: contents, range: range),
        let urlRange = Range(match.range(at: 1), in: contents)
    else {
        throw NSError(
            domain: "AppcastTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "could not find SUFeedURL in Scripts/make-app.sh"]
        )
    }
    return String(contents[urlRange])
}

@Test("Scripts/make-app.sh's SUFeedURL and make-appcast.sh's --output requirement name the same asset")
func feedURLAndScriptOutputAgreeOnFilename() throws {
    let feedURLString = try extractSUFeedURLFromMakeAppScript()
    let feedURL = try #require(URL(string: feedURLString))
    #expect(feedURL.host == "github.com")
    #expect(feedURL.lastPathComponent == "appcast.xml")

    let zip = try makeFixtureArchive(byteCount: 14)
    defer { try? FileManager.default.removeItem(at: zip) }
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("snitt-appcast-output-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // The script must accept the REAL basename taken from SUFeedURL...
    let rightPath = dir.appendingPathComponent(feedURL.lastPathComponent)
    let accepted = runScript(["1.0.0", zip.path, "https://example.test/S.zip", "sig", "--output", rightPath.path])
    #expect(accepted.status == 0)
    #expect(FileManager.default.fileExists(atPath: rightPath.path))

    // ...and refuse any other name, so a caller can never accidentally
    // publish a feed Sparkle's SUFeedURL will never request.
    let wrongPath = dir.appendingPathComponent("Snitt-appcast.xml")
    let refused = runScript(["1.0.0", zip.path, "https://example.test/S.zip", "sig", "--output", wrongPath.path])
    #expect(refused.status != 0)
    #expect(!FileManager.default.fileExists(atPath: wrongPath.path))
}

@Test("An --output write is atomic: a refused run never touches an existing good feed")
func outputWriteNeverTruncatesOnFailure() throws {
    // R35 (task-5-review.md): shell redirection (`> appcast.xml`)
    // truncates the destination before the script runs a single check.
    // `--output` exists specifically so a refused run leaves a
    // previously-published good feed untouched.
    let zip = try makeFixtureArchive(byteCount: 14)
    defer { try? FileManager.default.removeItem(at: zip) }
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("snitt-appcast-atomic-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let outputPath = dir.appendingPathComponent("appcast.xml")

    let goodContent = "GOOD-PREVIOUS-FEED-CONTENT-\(UUID().uuidString)"
    try goodContent.write(to: outputPath, atomically: true, encoding: .utf8)

    // No signature at all — this run MUST be refused.
    let refused = runScript(["1.0.0", zip.path, "https://example.test/S.zip", "--output", outputPath.path])
    #expect(refused.status != 0)

    let survivingContent = try String(contentsOf: outputPath, encoding: .utf8)
    #expect(survivingContent == goodContent)
}

// MARK: - Version agreement with the archive (R34, task-5-review.md)

/// Builds a real zip (via `/usr/bin/zip`, not raw bytes) containing
/// `Placeholder.app/Contents/Info.plist` with the given
/// `CFBundleShortVersionString`, so make-appcast.sh's own `unzip`/
/// `PlistBuddy` cross-check has a genuine archive to inspect — not the
/// plain-bytes fixture the other tests use, which this check silently
/// (and correctly) declines to open.
private func makeArchiveWithAppInfoPlist(bundleShortVersion: String) throws -> URL {
    let workDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("snitt-appcast-archive-src-\(UUID().uuidString)")
    let appContents = workDir.appendingPathComponent("Placeholder.app/Contents")
    try FileManager.default.createDirectory(at: appContents, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDir) }

    let plist: [String: Any] = ["CFBundleShortVersionString": bundleShortVersion]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: appContents.appendingPathComponent("Info.plist"))

    let zipPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("snitt-appcast-archive-\(UUID().uuidString).zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = workDir
    process.arguments = ["-r", "-q", zipPath.path, "Placeholder.app"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "AppcastTests", code: Int(process.terminationStatus))
    }
    return zipPath
}

@Test("A <version> argument that disagrees with the archive's own Info.plist is refused")
func archiveVersionMismatchIsRefused() throws {
    let zip = try makeArchiveWithAppInfoPlist(bundleShortVersion: "2.0.0")
    defer { try? FileManager.default.removeItem(at: zip) }

    let mismatched = runScript(["1.2.0", zip.path, "https://example.test/S.zip", "sig"])
    #expect(mismatched.status != 0)
    #expect(mismatched.stderr.contains("1.2.0"))
    #expect(mismatched.stderr.contains("2.0.0"))
    #expect(mismatched.stdout.isEmpty)

    let matching = runScript(["2.0.0", zip.path, "https://example.test/S.zip", "sig"])
    #expect(matching.status == 0)
}

/// Builds an archive shaped like a REAL Snitt release, not the flat
/// single-bundle fixture above: an outer `<name>.app/Contents/Info.plist`
/// PLUS a nested `Sparkle.framework/.../Downloader.xpc/Contents/Info.plist`
/// carrying a DIFFERENT version — exactly what `Scripts/notarize.sh`'s
/// `ditto -c -k --keepParent` produces, since Sparkle's embedded XPC
/// services and `Updater.app` each carry their own `Info.plist`.
///
/// The nested entry is added to the zip BEFORE the outer one (two
/// separate `zip` invocations, each appending one file), reproducing the
/// exact ordering `task-5-rereview.md`'s R38 found: the nested
/// `Contents/Info.plist` sorted first in `unzip -Z1`'s listing under real
/// `ditto` output, so an unanchored `grep -m1` picked Sparkle's own
/// version (observed: "2.9.6") instead of the app's.
private func makeArchiveWithNestedXPCBundle(
    outerVersion: String,
    nestedXPCVersion: String
) throws -> URL {
    let workDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("snitt-appcast-nested-src-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: workDir) }

    let outerContents = workDir.appendingPathComponent("SnittFixture.app/Contents")
    try FileManager.default.createDirectory(at: outerContents, withIntermediateDirectories: true)
    let outerPlistData = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleShortVersionString": outerVersion],
        format: .xml, options: 0
    )
    try outerPlistData.write(to: outerContents.appendingPathComponent("Info.plist"))

    let nestedRelativePath =
        "SnittFixture.app/Contents/MacOS/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents"
    let nestedContents = workDir.appendingPathComponent(nestedRelativePath)
    try FileManager.default.createDirectory(at: nestedContents, withIntermediateDirectories: true)
    let nestedPlistData = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleShortVersionString": nestedXPCVersion],
        format: .xml, options: 0
    )
    try nestedPlistData.write(to: nestedContents.appendingPathComponent("Info.plist"))

    let zipPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("snitt-appcast-nested-\(UUID().uuidString).zip")

    func appendToZip(_ relativePath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = workDir
        process.arguments = ["-q", zipPath.path, relativePath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "AppcastTests", code: Int(process.terminationStatus))
        }
    }

    // Nested entry FIRST, outer entry SECOND — the ordering that actually
    // broke the unanchored pattern.
    try appendToZip("\(nestedRelativePath)/Info.plist")
    try appendToZip("SnittFixture.app/Contents/Info.plist")

    return zipPath
}

@Test("The version check reads the outer app's own Info.plist, not a nested framework/XPC bundle's")
func archiveVersionMismatchReadsTheOuterAppNotANestedXPCBundle() throws {
    // R38 (task-5-rereview.md): with an unanchored pattern, this exact
    // shape made a CORRECT release get refused, forever — the nested
    // Sparkle XPC service's own version ("2.9.6" here) was read instead
    // of the app's ("9.9.9"), which never matches any real <version>
    // argument. This test's outer/nested versions deliberately DIFFER, so
    // the two cannot agree by coincidence: only reading the right one
    // passes.
    let zip = try makeArchiveWithNestedXPCBundle(outerVersion: "9.9.9", nestedXPCVersion: "2.9.6")
    defer { try? FileManager.default.removeItem(at: zip) }

    // Sanity: confirm the fixture actually reproduces the hazardous
    // ordering (nested entry listed before the outer one), so a passing
    // test below is not passing because the fixture accidentally didn't
    // reproduce the bug's precondition.
    let listing = Process()
    listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    listing.arguments = ["-Z1", zip.path]
    let listingOut = Pipe()
    listing.standardOutput = listingOut
    listing.standardError = Pipe()
    try listing.run()
    let listingText = String(data: listingOut.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    listing.waitUntilExit()
    let entries = listingText.split(separator: "\n").map(String.init)
    let nestedIndex = try #require(entries.firstIndex(where: { $0.hasSuffix("Downloader.xpc/Contents/Info.plist") }))
    let outerIndex = try #require(entries.firstIndex(of: "SnittFixture.app/Contents/Info.plist"))
    #expect(nestedIndex < outerIndex, "fixture must list the nested Info.plist before the outer one to reproduce R38")

    // The real assertion: the outer app's own version is what gets
    // checked, regardless of listing order.
    let matchingOuter = runScript(["9.9.9", zip.path, "https://example.test/S.zip", "sig"])
    #expect(matchingOuter.status == 0)
    #expect(matchingOuter.stderr.isEmpty)

    // And a version that matches the NESTED bundle but not the outer app
    // is still correctly refused — confirming this isn't "skip the check
    // entirely" in disguise.
    let matchingNestedOnly = runScript(["2.9.6", zip.path, "https://example.test/S.zip", "sig"])
    #expect(matchingNestedOnly.status != 0)
    #expect(matchingNestedOnly.stderr.contains("2.9.6"))
    #expect(matchingNestedOnly.stderr.contains("9.9.9"))
}

// MARK: - Sparkle-driven round trip

/// A minimal, single-purpose HTTP/1.1 server bound to loopback on an
/// ephemeral port, serving one fixed body to every connection it accepts.
/// Exists purely so a REAL `SPUUpdater` can fetch a REAL appcast over a
/// REAL network stack — the same code path production uses — rather than
/// asserting against the XML text this test process wrote itself.
private final class LocalFixedResponseServer: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private let body: Data

    // R36 (task-5-review.md): `listenFD` and `stopped` are read/written
    // from both the caller's thread and the accept-loop thread, and the
    // original version closed the fd directly under a `stop()` that could
    // race a thread blocked inside `accept()` on that same fd number — a
    // closed fd's integer can be reused by any other socket the process
    // opens under parallel test load, so a late-arriving `accept()` return
    // could then be operating on someone else's socket. `stateLock` makes
    // every read/write of `listenFD`/`stopped` mutually exclusive with
    // `stop()`, and `stop()` unblocks the accept loop by CONNECTING to it
    // (a normal, local, loopback-only connection) rather than yanking the
    // fd out from under it, then waits for the loop to actually exit
    // before closing anything.
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var stopped = false
    private let acceptLoopFinished = DispatchSemaphore(value: 0)

    enum SetupError: Error { case socket, bind, listen, getsockname }

    init(body: Data) throws {
        self.body = body
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SetupError.socket }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else { close(fd); throw SetupError.bind }
        guard listen(fd, 4) == 0 else { close(fd); throw SetupError.listen }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let sockNameResult = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard sockNameResult == 0 else { close(fd); throw SetupError.getsockname }

        self.listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.start()
    }

    private func acceptLoop() {
        while true {
            stateLock.lock()
            let fd = listenFD
            let isStopped = stopped
            stateLock.unlock()
            if isStopped || fd < 0 { break }

            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 { break }

            stateLock.lock()
            let stoppedAfterAccept = stopped
            stateLock.unlock()
            if stoppedAfterAccept {
                // This is `stop()`'s own unblocking connection, not a real
                // request — serve nothing and let the loop exit.
                close(clientFD)
                break
            }

            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = buffer.withUnsafeMutableBytes { recv(clientFD, $0.baseAddress, $0.count, 0) }
            var response = Data(
                "HTTP/1.1 200 OK\r\nContent-Type: application/xml\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    .utf8
            )
            response.append(body)
            response.withUnsafeBytes { rawBuffer in
                var sent = 0
                let total = rawBuffer.count
                while sent < total {
                    let result = send(clientFD, rawBuffer.baseAddress!.advanced(by: sent), total - sent, 0)
                    if result <= 0 { break }
                    sent += result
                }
            }
            close(clientFD)
        }
        acceptLoopFinished.signal()
    }

    func stop() {
        stateLock.lock()
        if stopped {
            stateLock.unlock()
            return
        }
        stopped = true
        let fd = listenFD
        let serverPort = port
        stateLock.unlock()

        guard fd >= 0 else { return }

        // Unblock a thread parked in `accept(fd, ...)` by connecting to it
        // ourselves, rather than closing `fd` out from under it.
        let unblocker = socket(AF_INET, SOCK_STREAM, 0)
        if unblocker >= 0 {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = serverPort.bigEndian
            _ = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(unblocker, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(unblocker)
        }

        // Only close the listening fd once the accept loop has actually
        // returned — this is what makes the fd-reuse race structurally
        // unreachable rather than merely unlikely.
        _ = acceptLoopFinished.wait(timeout: .now() + 2)
        close(fd)
    }

    deinit { stop() }
}

@MainActor
private final class AppcastCaptureDelegate: NSObject, SPUUpdaterDelegate {
    private(set) var appcast: SUAppcast?
    private(set) var abortError: Error?

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        self.appcast = appcast
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        abortError = error
    }
}

@MainActor
private final class RoundTripNoopUserDriver: NSObject, SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {}
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
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

/// A hand-built, unsigned `.app` fixture pointed at a private
/// `SUDefaultsDomain` suite (see `UpdaterControllerTests.swift`'s
/// `SparkleFixture` for the full rationale — every read/write Sparkle
/// performs against this bundle must land in a throwaway suite this
/// fixture owns and deletes, never in `com.impressiver.snitt`).
/// Captured once, before any fixture in this process can have written a
/// preferences file — see `sweepStaleAppcastFixtureFiles()` below.
private let appcastFixtureProcessStartTime = Date()

/// R33: `UpdaterControllerTests.swift`'s `SparkleFixture` sweeps stale
/// `com.snitt.test.fixture.*.plist` files left behind by a prior, killed
/// `swift test` run — without it, R24 notes, that is "unbounded growth,
/// one file per leaked run, forever." This fixture's suite prefix
/// (`com.snitt.test.appcast-fixture.`) does not match that sweep's
/// `hasPrefix("com.snitt.test.fixture.")` check, so it needs its own —
/// otherwise this fixture reaches the exact unbounded-leak failure mode
/// R24 exists to prevent, just under a different prefix. Only removes
/// files strictly OLDER than this process's own start time, for the same
/// reason `SparkleFixture` does: a file this process itself just created
/// can never be mistaken for a stale one, so this can never delete a
/// fixture concurrently in use within this same process.
private func sweepStaleAppcastFixtureFiles() {
    guard let preferencesDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Preferences") else { return }
    guard let contents = try? FileManager.default.contentsOfDirectory(
        at: preferencesDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey]
    ) else { return }
    for file in contents where file.lastPathComponent.hasPrefix("com.snitt.test.appcast-fixture.") {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let modified, modified < appcastFixtureProcessStartTime else { continue }
        try? FileManager.default.removeItem(at: file)
    }
}

@MainActor
private func makeRoundTripFixture(feedURL: String) throws -> (bundle: Bundle, root: URL, suite: String) {
    sweepStaleAppcastFixtureFiles()
    let suite = "com.snitt.test.appcast-fixture.\(UUID().uuidString)"
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SnittAppcastFixture-\(UUID().uuidString).app")
    let contents = root.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

    let meaninglessPublicKey = Data(count: 32).base64EncodedString()
    let plist: [String: Any] = [
        "CFBundleIdentifier": "com.snitt.test.appcast-fixture",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1.0",
        "SUFeedURL": feedURL,
        "SUPublicEDKey": meaninglessPublicKey,
        "SUEnableAutomaticChecks": false,
        "SUDefaultsDomain": suite,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))

    // Pre-decide the permission prompt and seed a recent check time so
    // `checkForUpdateInformation()` below goes straight to the network
    // fetch instead of stalling on a permission decision this fixture has
    // no UI to make.
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(true, forKey: "SUHasLaunchedBefore")
    defaults.set(Date(), forKey: "SULastCheckTime")
    defaults.set(false, forKey: "SUEnableAutomaticChecks")

    let bundle = try #require(Bundle(url: root), "could not open the appcast test fixture as a bundle")
    return (bundle, root, suite)
}

@MainActor
private func cleanUpRoundTripFixture(root: URL, suite: String) {
    // `synchronize()` returning is not a guarantee the write already
    // landed on disk — `cfprefsd` can flush a domain's dirty state a
    // couple of milliseconds later via its own XPC round trip, especially
    // under the full suite's parallel load. A bounded retry closes that
    // window — see `UpdaterControllerTests.swift`'s
    // `SparkleFixture.cleanUp()`, which hit the same race first.
    //
    // R37: delete, THEN wait once and check — if the file is still gone
    // after that one window, stop; only a recreation (the race actually
    // firing) costs a further delete-and-wait cycle. The common case (no
    // race) costs one 50ms wait instead of nine, which is what the
    // original "without adding meaningful time" comment claimed but the
    // unconditional 10-iteration loop it described did not actually do.
    let defaults = UserDefaults(suiteName: suite)
    defaults?.removePersistentDomain(forName: suite)
    defaults?.synchronize()
    if let preferencesURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Preferences")
        .appendingPathComponent("\(suite).plist")
    {
        for attempt in 0..<10 {
            try? FileManager.default.removeItem(at: preferencesURL)
            guard attempt < 9 else { break }
            Thread.sleep(forTimeInterval: 0.05)
            if !FileManager.default.fileExists(atPath: preferencesURL.path) {
                break
            }
        }
    }
    try? FileManager.default.removeItem(at: root)
}

@MainActor
/// Polls `condition` until it holds or `timeout` elapses.
///
/// 180s, raised from 60 on 2026-09-07. The waits guarded by this are real
/// `SPUUpdater` scheduler and XPC round-trips, whose latency scales with machine
/// load rather than with anything the assertion is about. The 60s ceiling was
/// calibrated before the suite gained waveform and filmstrip sampling — tests
/// that read every audio sample and decode video frames — and after that both
/// this file's updater tests and `AppcastTests` began timing out at ~64s in
/// full-suite runs while passing in isolation in under a second.
///
/// `SparkleTestGate` already serialises updater tests against EACH OTHER; it
/// cannot serialise them against the rest of the suite. Raising the ceiling
/// changes only how long we wait for a real answer, never what counts as one —
/// a feed that genuinely fails to parse still fails, just later.
private func waitUntil(timeout: TimeInterval = 180, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}

@MainActor
@Test("A stale round-trip fixture preference file is swept on the next fixture creation")
func staleAppcastFixtureFileIsSwept() throws {
    // R33 (task-5-review.md): `UpdaterControllerTests.swift`'s
    // `sweepStaleFixtureFiles()` only matches
    // `com.snitt.test.fixture.*` and does nothing for this file's
    // `com.snitt.test.appcast-fixture.*` suite — that domain had NO sweep
    // at all before `sweepStaleAppcastFixtureFiles()` was added, i.e. a
    // leaked file from a killed run would accumulate forever, one per
    // leak, exactly what R24 added the original sweep to prevent for the
    // other fixture. This directly exercises that fix: plant a
    // fixture-shaped preferences file, backdate it before this process's
    // own `appcastFixtureProcessStartTime`, and confirm the very next
    // fixture creation removes it.
    guard let preferencesDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Preferences")
    else {
        Issue.record("could not resolve ~/Library/Preferences")
        return
    }
    let staleFile = preferencesDirectory
        .appendingPathComponent("com.snitt.test.appcast-fixture.STALE-\(UUID().uuidString).plist")
    try Data("stale".utf8).write(to: staleFile)
    defer { try? FileManager.default.removeItem(at: staleFile) }

    // Backdate it to well before this process started, so it unambiguously
    // qualifies as "leaked by an earlier run" rather than "created just
    // now by this test" — the same distinction
    // `sweepStaleAppcastFixtureFiles()` itself draws.
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 0)],
        ofItemAtPath: staleFile.path
    )
    #expect(FileManager.default.fileExists(atPath: staleFile.path))

    let (_, root, suite) = try makeRoundTripFixture(feedURL: "https://example.invalid/appcast.xml")
    defer { cleanUpRoundTripFixture(root: root, suite: suite) }

    #expect(!FileManager.default.fileExists(atPath: staleFile.path))
}

@MainActor
@Test("Sparkle's own SUAppcast parses the generated feed and yields the item")
func sparkleParsesTheGeneratedFeed() async throws {
    // `SparkleTestGate` (Tests/SnittAppTests/SparkleTestGate.swift): this
    // test drives a REAL `SPUUpdater` against a REAL local HTTP server, and
    // was observed failing intermittently under the full suite — always
    // timing out its `waitUntil` below with `delegate.appcast` still nil —
    // while passing every time in isolation. `UpdaterControllerTests.swift`
    // and `BundleLayoutTests.swift` each also drive a real `SPUUpdater`, as
    // unserialized top-level tests, so without this gate this test's wait
    // can starve behind (or interleave with) another suite's updater's own
    // XPC/scheduler activity. Confirmed by reproducing the failure on
    // demand under artificial CPU load, then confirming it disappears with
    // the gate in place.
    try await SparkleTestGate.run {
        let zip = try makeFixtureArchive(byteCount: 555)
        defer { try? FileManager.default.removeItem(at: zip) }

        let releaseURL = "https://example.test/downloads/Snitt-7.8.9.zip"
        let scriptResult = runScript(
            ["7.8.9", zip.path, releaseURL],
            env: ["SPARKLE_SIGNATURE": "test-signature-not-a-real-key-BpFq2"]
        )
        #expect(scriptResult.status == 0)
        let appcastData = try #require(scriptResult.stdout.data(using: .utf8))

        let server = try LocalFixedResponseServer(body: appcastData)
        defer { server.stop() }

        let (bundle, root, suite) = try makeRoundTripFixture(feedURL: "http://127.0.0.1:\(server.port)/appcast.xml")
        defer { cleanUpRoundTripFixture(root: root, suite: suite) }

        let delegate = AppcastCaptureDelegate()
        let updater = SPUUpdater(
            hostBundle: bundle,
            applicationBundle: bundle,
            userDriver: RoundTripNoopUserDriver(),
            delegate: delegate
        )
        try updater.start()
        updater.checkForUpdateInformation()

        try await waitUntil { delegate.appcast != nil || delegate.abortError != nil }

        if let abortError = delegate.abortError {
            Issue.record("Sparkle aborted loading the generated feed: \(abortError)")
            return
        }

        let appcast = try #require(delegate.appcast, "Sparkle never reported loading the generated feed")
        let item = try #require(appcast.items.first)

        // Real properties Sparkle's OWN parser populated from OUR script's
        // output — not a string this test wrote and is now reading back.
        #expect(item.versionString == "7.8.9")
        #expect(item.displayVersionString == "7.8.9")
        #expect(item.fileURL?.absoluteString == releaseURL)
        #expect(item.contentLength == 555)

        // The enclosure's edSignature isn't exposed as a first-class property
        // (Sparkle only verifies it internally at download time), but it IS in
        // `propertiesDictionary` — the raw dictionary Sparkle's own XML parser
        // built from the enclosure's attributes. Reading it back here proves
        // Sparkle's parser extracted OUR signature value intact, not that our
        // own generator emitted a string that merely looks right.
        let enclosureProperties = item.propertiesDictionary["enclosure"] as? [String: Any]
        let parsedSignature = enclosureProperties?["sparkle:edSignature"] as? String
        #expect(parsedSignature == "test-signature-not-a-real-key-BpFq2")
    }
}

// MARK: - Cryptographic validity

/// A fresh, throwaway Ed25519 private key — 32 random bytes, which IS the
/// key's "seed" in the format `sign_update -f` reads directly (its
/// `--help` documents this as base64 of the raw 32-byte private seed,
/// exactly what `generate_keys -x` would export). Generated with
/// `SecRandomCopyBytes` (no external process, no PATH dependency on a
/// particular `openssl` build) and never written to the Keychain —
/// `generate_keys` would do that, which is exactly the side effect this
/// test avoids by not using it. `sign_update --verify -f <seed-file>`
/// derives the matching public key internally, so this test never needs
/// to compute or carry a separate public key. Lives only under a temp
/// file for the duration of one test and is deleted immediately after;
/// never written to this repo, never logged.
private struct EphemeralEdKeyPair {
    let seedBase64: String

    static func generate() throws -> EphemeralEdKeyPair {
        var seed = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, seed.count, &seed)
        guard status == errSecSuccess else {
            throw NSError(domain: "EphemeralEdKeyPair", code: Int(status))
        }
        return EphemeralEdKeyPair(seedBase64: Data(seed).base64EncodedString())
    }
}

private func signUpdateVerify(seedFile: URL, artifact: URL, signature: String) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: signUpdatePath)
    process.arguments = ["--verify", "-f", seedFile.path, artifact.path, signature]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

@Test(
    "The emitted signature is cryptographically valid for the exact archive it describes",
    .enabled(if: signUpdateIsAvailable, signUpdateSkipReason)
)
func theSignatureIsCryptographicallyValid() throws {
    let keyPair = try EphemeralEdKeyPair.generate()
    let seedFile = FileManager.default.temporaryDirectory.appendingPathComponent("snitt-seed-\(UUID().uuidString).b64")
    try keyPair.seedBase64.write(to: seedFile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: seedFile) }

    let zip = try makeFixtureArchive(byteCount: 4096)
    defer { try? FileManager.default.removeItem(at: zip) }

    // Sign the REAL archive with Sparkle's OWN signing tool — this is the
    // signature a real release would carry, produced the real way, just
    // with a throwaway key instead of the maintainer's.
    let signProcess = Process()
    signProcess.executableURL = URL(fileURLWithPath: signUpdatePath)
    signProcess.arguments = ["-f", seedFile.path, "-p", zip.path]
    let signOut = Pipe()
    signProcess.standardOutput = signOut
    signProcess.standardError = Pipe()
    try signProcess.run()
    let signature = String(
        data: signOut.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    signProcess.waitUntilExit()
    #expect(signProcess.terminationStatus == 0)
    #expect(!signature.isEmpty)

    let out = runScript(["1.0.0", zip.path, "https://example.test/S.zip", signature])
    #expect(out.status == 0)

    let document = try XMLDocument(xmlString: out.stdout, options: [])
    let enclosures = try document.nodes(forXPath: "//enclosure")
    let enclosure = try #require(enclosures.first as? XMLElement)
    let emittedSignature = try #require(enclosure.attribute(forName: "sparkle:edSignature")?.stringValue)
    #expect(emittedSignature == signature)

    // Sparkle's own verifier, using the matching public key, accepts it
    // against the exact archive it describes...
    #expect(signUpdateVerify(seedFile: seedFile, artifact: zip, signature: emittedSignature) == 0)

    // ...and REJECTS it against a tampered archive. If this ever passed,
    // the "signature" the script emits would not actually be bound to the
    // artifact it claims to cover.
    let tamperedZip = FileManager.default.temporaryDirectory
        .appendingPathComponent("snitt-appcast-tampered-\(UUID().uuidString).zip")
    try Data(repeating: 0x42, count: 4096).write(to: tamperedZip)
    defer { try? FileManager.default.removeItem(at: tamperedZip) }
    #expect(signUpdateVerify(seedFile: seedFile, artifact: tamperedZip, signature: emittedSignature) != 0)
}
