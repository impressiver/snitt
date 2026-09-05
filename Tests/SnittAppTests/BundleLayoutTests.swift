import Testing
import Foundation

// M5b Task 2: Snitt.app must embed Sparkle.framework signed INSIDE-OUT.
//
// `codesign` signs inner code before the enclosing bundle. Sign the outer
// bundle after copying in an unsigned framework and the app launches fine
// from Finder on this machine but fails Gatekeeper on someone else's — a
// failure with no local reproduction. These tests hold make-app.sh to the
// order (framework first, then bundle) and to the chosen embed location.
//
// All of them skip cleanly when build/Snitt.app does not exist, so a plain
// `swift test` never fails for want of a build. That also means a CI run
// with no build step exercises none of this file — see the task report.

private let app = URL(fileURLWithPath: "build/Snitt.app")

// Contents/MacOS/, not Contents/Frameworks/: spike S9 measured the rpath SwiftPM
// emits as @loader_path, which resolves relative to the executable at
// Contents/MacOS/Snitt. Sparkle.framework living beside it there needs no
// install_name_tool rpath surgery. Contents/Frameworks/ is the more
// conventional location but would require adding
// @executable_path/../Frameworks by hand for no offsetting benefit here.
private let framework = app.appending(path: "Contents/MacOS/Sparkle.framework")

private func requireBuiltApp() throws {
    try #require(
        FileManager.default.fileExists(atPath: app.path),
        "run ./Scripts/make-app.sh first"
    )
}

/// Runs `codesign --verify --deep --strict` against a path and reports
/// whether it exited zero. `--deep` walks into nested code (the embedded
/// framework, when run against the app) rather than checking the outer
/// signature alone.
private func codesignVerifies(_ url: URL) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    process.arguments = ["--verify", "--deep", "--strict", url.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

private func plistOf(_ app: URL) throws -> [String: Any] {
    let plistURL = app.appending(path: "Contents/Info.plist")
    let data = try Data(contentsOf: plistURL)
    let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    return try #require(plist as? [String: Any])
}

@Test("The built app embeds Sparkle.framework at Contents/MacOS")
func builtAppEmbedsSparkleAtChosenLocation() throws {
    try requireBuiltApp()
    #expect(FileManager.default.fileExists(atPath: framework.path))
}

@Test("Both the embedded framework and the outer app verify with codesign --deep --strict")
func frameworkAndAppAreBothSigned() throws {
    try requireBuiltApp()
    try #require(FileManager.default.fileExists(atPath: framework.path), "Sparkle.framework missing — cannot test signing order")

    // Signed INSIDE-OUT: sign the framework before the bundle. If make-app.sh
    // ever regresses to signing the app first (or skips the framework), the
    // framework itself was never signed and this fails even though the app's
    // own outer signature can still look fine in isolation.
    #expect(codesignVerifies(framework), "Sparkle.framework does not verify — was it signed before the app?")
    #expect(codesignVerifies(app), "Snitt.app does not verify --deep --strict")
}

@Test("Info.plist declares Sparkle's feed and defaults automatic checks off")
func infoPlistDeclaresSparkleKeys() throws {
    try requireBuiltApp()
    let plist = try plistOf(app)

    #expect(plist["SUFeedURL"] != nil)
    #expect(plist["SUPublicEDKey"] != nil)
    // Ruling R3: false is the cold-start default. An update check is a
    // network request announcing this machine runs Snitt, made at a moment
    // the user did not choose. Task 3 adds a user-facing setting that
    // governs this at runtime; until then, the plist must not opt a fresh
    // install into checking.
    #expect(plist["SUEnableAutomaticChecks"] as? Bool == false)
}
