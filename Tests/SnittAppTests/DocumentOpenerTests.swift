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

    @Test("Opening a path that is not a .snitt bundle throws rather than opening an empty window")
    func rejectsNonBundle() async throws {
        let junk = FileManager.default.temporaryDirectory
            .appending(path: "not-a-bundle-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }

        let before = EditorWindowController.openWindowCount
        await #expect(throws: (any Error).self) {
            _ = try await DocumentOpener.open(bundleURL: junk)
        }
        // The failure that matters is a half-open editor showing nothing.
        #expect(EditorWindowController.openWindowCount == before)
    }
}
