import Testing
import AppKit
import Foundation
@testable import SnittApp
@testable import SnittDocument

/// Task 7 (D46): a GUI trim persists to disk, and undo — the only way back
/// once autosave means every trim reaches disk immediately — is multi-level
/// and persists too.
///
/// `.serialized`, and `init()` touches `NSApplication.shared` once before
/// any test body runs, for the same two reasons `DocumentOpenerTests` and
/// `EditorWindowControllerTests` do: these tests construct real, real-EDL
/// `EditorWindowController`s through `DocumentOpener.open`, which shows a
/// real front-ordered `NSWindow`. Every test body additionally runs inside
/// `EditorWindowTestGate` (added alongside this suite) — none of these
/// tests assert `EditorWindowController.openWindowCount` themselves, but
/// opening a real window here still bumps that process-global counter, and
/// without the gate that bump can land inside another concurrently-running
/// suite's own before/after snapshot of it. Confirmed empirically: without
/// the gate, adding this suite made `EditorWindowControllerTests`'s
/// open-count assertions fail intermittently (2 of 4 full-suite runs).
@Suite(.serialized)
@MainActor
struct EditorPersistenceTests {
    init() { _ = NSApplication.shared }

    /// Long enough (12s of media) to hold three non-overlapping 1-second
    /// cuts at 1s, 5s, and 9s with room on every side.
    private func makeFixtureBundle() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "fixture-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 12)
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)
        try EventLog(events: []).write(to: bundle)
        try EditDecisionList.fullRange().write(to: bundle)
        return url
    }

    @Test("A trim is on disk before the window closes")
    func trimPersists() async throws {
        let url = try await makeFixtureBundle()
        defer { try? FileManager.default.removeItem(at: url) }

        try await EditorWindowTestGate.run {
            let controller = try await DocumentOpener.open(bundleURL: url)
            defer { controller.close() }

            controller.applyTrimForTesting(TimeRange(start: 1.0, end: 3.0))
            await controller.waitForPendingSaveForTesting()

            // Read the EDL back OFF DISK. Asserting the in-memory edl has the
            // cut is what the old code already did correctly — it is the
            // adjacent property, and it passes against the bug this test
            // exists to catch.
            let reloaded = try EditDecisionList.read(from: SnittBundle(opening: url))
            #expect(reloaded.cuts.count == 1)
        }
    }

    @Test("Reopening a trimmed document shows the trim")
    func trimSurvivesReopen() async throws {
        let url = try await makeFixtureBundle()
        defer { try? FileManager.default.removeItem(at: url) }

        try await EditorWindowTestGate.run {
            let first = try await DocumentOpener.open(bundleURL: url)
            first.applyTrimForTesting(TimeRange(start: 1.0, end: 3.0))
            await first.waitForPendingSaveForTesting()
            first.close()

            let second = try await DocumentOpener.open(bundleURL: url)
            defer { second.close() }
            // The end-to-end property D45 claimed and did not deliver.
            #expect(second.currentEDLForTesting().cuts.count == 1)
        }
    }

    @Test("Undo removes the cut, and the removal persists")
    func undoPersists() async throws {
        let url = try await makeFixtureBundle()
        defer { try? FileManager.default.removeItem(at: url) }

        try await EditorWindowTestGate.run {
            let controller = try await DocumentOpener.open(bundleURL: url)
            defer { controller.close() }

            controller.applyTrimForTesting(TimeRange(start: 1.0, end: 3.0))
            await controller.waitForPendingSaveForTesting()
            controller.undoManager?.undo()
            await controller.waitForPendingSaveForTesting()

            // Undo that reverts memory but not disk is the same divergence this
            // task exists to remove, pointing the other way.
            let reloaded = try EditDecisionList.read(from: SnittBundle(opening: url))
            #expect(reloaded.cuts.isEmpty)
        }
    }

    @Test("Undo is multi-level, not one-deep")
    func undoIsMultiLevel() async throws {
        let url = try await makeFixtureBundle()
        defer { try? FileManager.default.removeItem(at: url) }

        try await EditorWindowTestGate.run {
            let controller = try await DocumentOpener.open(bundleURL: url)
            defer { controller.close() }

            // Awaited individually, not batched: each `applyTrimForTesting`
            // call starts its own unstructured `Task` (apply, then persist).
            // Batching all three before the first await would let them
            // interleave on the main actor and race each other's writes to
            // the same file — a scheduling hazard, not a property of undo,
            // and not something this test exists to pin down.
            controller.applyTrimForTesting(TimeRange(start: 1.0, end: 2.0))
            await controller.waitForPendingSaveForTesting()
            controller.applyTrimForTesting(TimeRange(start: 5.0, end: 6.0))
            await controller.waitForPendingSaveForTesting()
            controller.applyTrimForTesting(TimeRange(start: 9.0, end: 10.0))
            await controller.waitForPendingSaveForTesting()

            // Same interleaving hazard as above applies to the two `undo()`
            // calls' persist tasks — await between them so the final on-disk
            // read reflects the second undo, not whichever task's write
            // landed last by accident.
            controller.undoManager?.undo()
            await controller.waitForPendingSaveForTesting()
            controller.undoManager?.undo()
            await controller.waitForPendingSaveForTesting()

            // A single-level undo passes a one-undo test. Three cuts and two
            // undos is the smallest case that distinguishes a stack from a
            // last-value restore.
            let reloaded = try EditDecisionList.read(from: SnittBundle(opening: url))
            #expect(reloaded.cuts.count == 1)
        }
    }
}
