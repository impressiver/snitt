import Testing
import AppKit
import Foundation
@testable import SnittApp
@testable import SnittDocument

@Suite(.serialized)
@MainActor
struct DocumentOpenerTests {
    init() { _ = NSApplication.shared }

    /// Builds a real `.snitt` bundle on disk in a temp directory. Not a mock:
    /// the property under test is that a bundle written by Snitt can be read
    /// back and opened, and a fake bundle would test the fake.
    private func makeFixtureBundle() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "fixture-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 1)
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)
        try EventLog(events: []).write(to: bundle)
        try EditDecisionList.fullRange().write(to: bundle)
        return url
    }

    @Test("A .snitt bundle on disk opens into an editor window")
    func opensARealBundle() async throws {
        let url = try await makeFixtureBundle()
        defer { try? FileManager.default.removeItem(at: url) }

        let before = EditorWindowController.openWindowCount
        let controller = try await DocumentOpener.open(bundleURL: url)
        defer { controller.close() }

        // Assert the OUTCOME — a window exists — not that a function was
        // called. "openEditor was invoked" passes against an implementation
        // that throws inside and swallows it.
        #expect(EditorWindowController.openWindowCount == before + 1)
        #expect(controller.window.title == url.lastPathComponent)
    }

    @Test("Opening a path that is not a directory throws SnittBundleError.notADirectory rather than opening an empty window")
    func rejectsNonBundle() async throws {
        let junk = FileManager.default.temporaryDirectory
            .appending(path: "not-a-bundle-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }

        let before = EditorWindowController.openWindowCount
        // Assert the SPECIFIC rejection, not just "something threw": an
        // implementation that swallows `SnittBundle(opening:)`'s error and
        // falls through to, say, the parent directory would still satisfy
        // a bare `#expect(throws: (any Error).self)` — `EventLog.read`
        // would throw a *different* error next, and the test would pass
        // for the wrong reason. Pinning the error to
        // `SnittBundleError.notADirectory` means only the intended
        // rejection — "this path is not a bundle directory at all" — can
        // satisfy it.
        await #expect(throws: SnittBundleError.notADirectory) {
            _ = try await DocumentOpener.open(bundleURL: junk)
        }
        // The failure that matters is a half-open editor showing nothing.
        // NOTE: this assertion is unfalsifiable by construction, not just
        // in practice — `BuiltComposition`'s memberwise init is internal
        // to `SnittExport`, so no `SnittApp` implementation, however
        // broken, can construct one to hand `PreviewController` without
        // first getting through `CompositionBuilder.build`. The "no empty
        // editor" contract holds structurally; this line documents that
        // rather than being the thing enforcing it.
        #expect(EditorWindowController.openWindowCount == before)
    }

    @Test("Opening a directory that looks like a bundle but has no bundle contents throws rather than opening an empty window")
    func rejectsInvalidBundleDirectory() async throws {
        // The likelier real-world case: a plain folder someone renamed to
        // `.snitt`, or a bundle a failed recording never finished writing.
        // `SnittBundle(opening:)` only checks "is this a directory" — it
        // has no `missingCapture` check wired up — so this one gets past
        // that guard and must be rejected further in, when `EventLog.read`
        // can't find `events.json`.
        let empty = FileManager.default.temporaryDirectory
            .appending(path: "not-really-a-bundle-\(UUID().uuidString).snitt")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let before = EditorWindowController.openWindowCount
        await #expect(throws: CocoaError.self) {
            _ = try await DocumentOpener.open(bundleURL: empty)
        }
        #expect(EditorWindowController.openWindowCount == before)
    }
}
