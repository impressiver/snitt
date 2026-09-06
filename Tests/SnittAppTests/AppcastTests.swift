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
    // Sparkle rejects an unsigned update at INSTALL time — after the user
    // has downloaded it and waited. Failing here costs a release; failing
    // there costs the user's trust.
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

// MARK: - Sparkle-driven round trip

/// A minimal, single-purpose HTTP/1.1 server bound to loopback on an
/// ephemeral port, serving one fixed body to every connection it accepts.
/// Exists purely so a REAL `SPUUpdater` can fetch a REAL appcast over a
/// REAL network stack — the same code path production uses — rather than
/// asserting against the XML text this test process wrote itself.
private final class LocalFixedResponseServer: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private var listenFD: Int32 = -1
    private let body: Data
    private var acceptThread: Thread?

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
        self.acceptThread = thread
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 { break }
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = buffer.withUnsafeMutableBytes { recv(clientFD, $0.baseAddress, $0.count, 0) }
            var response = Data(
                "HTTP/1.1 200 OK\r\nContent-Type: application/xml\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    .utf8
            )
            response.append(body)
            response.withUnsafeBytes { _ = send(clientFD, $0.baseAddress, $0.count, 0) }
            close(clientFD)
        }
    }

    func stop() {
        if listenFD >= 0 {
            let fd = listenFD
            listenFD = -1
            close(fd)
        }
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
@MainActor
private func makeRoundTripFixture(feedURL: String) throws -> (bundle: Bundle, root: URL, suite: String) {
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
    // window without adding meaningful time to the run — see
    // `UpdaterControllerTests.swift`'s `SparkleFixture.cleanUp()`, which
    // hit and fixed the exact same race first.
    let defaults = UserDefaults(suiteName: suite)
    defaults?.removePersistentDomain(forName: suite)
    defaults?.synchronize()
    if let preferencesURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Preferences")
        .appendingPathComponent("\(suite).plist")
    {
        for attempt in 0..<10 {
            try? FileManager.default.removeItem(at: preferencesURL)
            if attempt < 9 {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
    try? FileManager.default.removeItem(at: root)
}

@MainActor
private func waitUntil(timeout: TimeInterval = 60, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}

@MainActor
@Test("Sparkle's own SUAppcast parses the generated feed and yields the item")
func sparkleParsesTheGeneratedFeed() async throws {
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

@Test("The emitted signature is cryptographically valid for the exact archive it describes")
func theSignatureIsCryptographicallyValid() throws {
    guard FileManager.default.isExecutableFile(atPath: signUpdatePath) else {
        Issue.record("sign_update not found at \(signUpdatePath) — Sparkle SPM artifacts not resolved; cannot verify signature cryptographically")
        return
    }

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
