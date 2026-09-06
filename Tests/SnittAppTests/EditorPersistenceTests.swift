import Testing
import AppKit
import Foundation
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

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

/// A `PreviewController` whose `apply` takes a caller-chosen amount of time.
///
/// The whole point of F2's test is that the FIRST autosave must finish
/// writing before the SECOND one does, however long each one's compositor
/// rebuild takes. Real builds of two real EDLs take roughly the same few
/// milliseconds and finish in whatever order the scheduler picks, so a test
/// that relied on real timing would pass against the unserialized code
/// nearly always. Making the first `apply` deliberately slow inverts the
/// completion order every single run: the older save is guaranteed to be
/// the one still in flight when the newer one is ready to write.
@MainActor
private final class DelayingPreviewController: PreviewController {
    /// Consumed one entry per `apply` call, in order; an empty queue means
    /// no delay.
    var applyDelays: [UInt64] = []

    override func apply(edl: EditDecisionList, events: [LoggedEvent]) async throws {
        let delay = applyDelays.isEmpty ? 0 : applyDelays.removeFirst()
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        try await super.apply(edl: edl, events: events)
    }
}

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


    /// F1 (whole-branch review), CRITICAL: `applyAndSave` ran
    /// `try? await apply` and then an UNCONDITIONAL `try? persist`, so an
    /// EDL the compositor REJECTED was written to disk anyway. One drag
    /// across the whole timeline throws `CompositionError.everythingCut`,
    /// and once that EDL is on disk `DocumentOpener.open` throws it forever:
    /// D45's own defect — a `.snitt` that can be written and never reopened
    /// — reintroduced by D46's autosave.
    ///
    /// Three properties, in the order they matter: the rejected EDL is not
    /// on disk, the document still opens, and the user is told rather than
    /// left looking at a preview that silently never changed.
    @Test("A trim the compositor rejects never reaches disk, and the document still opens")
    func rejectedTrimDoesNotReachDiskAndTheDocumentStillOpens() async throws {
        let url = try await makeFixtureBundle()
        defer { try? FileManager.default.removeItem(at: url) }

        try await EditorWindowTestGate.run {
            let controller = try await DocumentOpener.open(bundleURL: url)
            // The real path raises an `NSAlert`, which runs modal and has no
            // one to click it here; observe the refusal instead.
            var refusals: [Error] = []
            controller.onEditRejectedForTesting = { refusals.append($0) }

            // A drag across the whole timeline. `CompositionBuilder` rejects
            // it (`everythingCut`) — this is a real gesture, not a contrived
            // EDL: the timeline view can produce exactly this range.
            controller.applyTrimForTesting(TimeRange(start: 0.0, end: 100.0))
            await controller.waitForPendingSaveForTesting()

            let reloaded = try EditDecisionList.read(from: SnittBundle(opening: url))
            #expect(reloaded.cuts.isEmpty,
                    "an EDL the compositor rejected must not be written: \(reloaded.cuts)")

            // The preview never changed, so the in-memory EDL must not claim
            // the cut either — a screen showing a state that never reached
            // disk is the divergence this milestone exists to remove.
            #expect(controller.currentEDLForTesting().cuts.isEmpty,
                    "a refused trim must not be left showing in the editor's own EDL")

            // Silence is the third failure mode: skipping the write while
            // saying nothing leaves the user looking at a drag that appears
            // to have done nothing at all.
            #expect(refusals.count == 1, "the user must be told the edit was refused")

            controller.close()

            // The property D45 named: the bundle still opens. Against the
            // unconditional write this throws `everythingCut` forever.
            let reopened = try await DocumentOpener.open(bundleURL: url)
            reopened.close()
        }
    }

    /// F4 (whole-branch review): redo ships in the Edit menu (⌘⇧Z) and
    /// nothing pinned it. Task 7's prescribed mutation — dropping
    /// `registerUndo` from inside `restore` — turned out to affect ONLY
    /// redo and left the whole suite green, which is how we know redo was
    /// unobserved. This is the test that observes it, and it reads the EDL
    /// back OFF DISK: a redo that reverts memory without persisting is the
    /// same divergence undo was made to avoid, pointing the third way.
    @Test("Redo reinstates an undone cut, and the reinstatement persists")
    func redoReinstatesTheCutAndPersists() async throws {
        let url = try await makeFixtureBundle()
        defer { try? FileManager.default.removeItem(at: url) }

        try await EditorWindowTestGate.run {
            let controller = try await DocumentOpener.open(bundleURL: url)
            defer { controller.close() }

            controller.applyTrimForTesting(TimeRange(start: 1.0, end: 3.0))
            await controller.waitForPendingSaveForTesting()
            controller.undoManager?.undo()
            await controller.waitForPendingSaveForTesting()
            #expect(try EditDecisionList.read(from: SnittBundle(opening: url)).cuts.isEmpty,
                    "precondition: the undo must have landed before redo is meaningful")

            controller.undoManager?.redo()
            await controller.waitForPendingSaveForTesting()

            let reloaded = try EditDecisionList.read(from: SnittBundle(opening: url))
            #expect(reloaded.cuts.count == 1,
                    "redo must put the cut back, on disk as well as on screen")
        }
    }


    /// F2 (whole-branch review), MAJOR: `pendingSaveTask` was overwritten on
    /// every trim and never awaited or cancelled, so two trims issued inside
    /// one compositor-build window ran as two concurrent, unstructured
    /// `Task`s. Task A carried the EDL as of trim A; Task B carried both
    /// cuts. If A's `persist` landed last, disk held ONE cut while the
    /// screen showed two — the silent memory/disk divergence D46 exists to
    /// eliminate, pointing the same direction as the bug it fixed.
    ///
    /// `undoIsMultiLevel` above steps around this hazard by awaiting between
    /// every trim, and says so. This test is the one that walks into it: two
    /// trims with no await between them, the first one's rebuild made slow
    /// so the inversion is deterministic rather than lucky.
    ///
    /// It also pins `waitForPendingSaveForTesting`: it must await the whole
    /// chain of saves, not just the most recently created task.
    @Test("A later trim is not overwritten on disk by an earlier trim's save")
    func laterTrimIsNotOverwrittenByAnEarlierSave() async throws {
        let url = try await makeFixtureBundle()
        defer { try? FileManager.default.removeItem(at: url) }

        try await EditorWindowTestGate.run {
            let bundle = try SnittBundle(opening: url)
            let built = try await CompositionBuilder.build(
                bundle: bundle, edl: .fullRange(), scale: 1.0)
            let controller = DelayingPreviewController(
                built: built, jumpPoints: [], bundle: bundle, scale: 1.0)
            let editor = EditorWindowController(
                controller: controller, title: url.lastPathComponent,
                bundleURL: url, edl: .fullRange(), events: [])

            // The first trim's rebuild takes 300ms; the second's is
            // immediate. Unserialized, the second write lands first and the
            // first write — carrying only ONE cut — overwrites it.
            controller.applyDelays = [300_000_000, 0]
            editor.applyTrimForTesting(TimeRange(start: 1.0, end: 2.0))
            editor.applyTrimForTesting(TimeRange(start: 5.0, end: 6.0))
            await editor.waitForPendingSaveForTesting()
            // Then give a STRAY write time to land. This sleep is not
            // waiting for correct behaviour — with the saves serialized the
            // await above has already drained the whole chain and nothing
            // else can write — it exists so the unserialized code cannot
            // pass by having its losing write arrive after the assertion.
            // A sleep that can only make a test stricter is not the flake
            // this project has paid for before.
            try await Task.sleep(nanoseconds: 900_000_000)

            let reloaded = try EditDecisionList.read(from: SnittBundle(opening: url))
            #expect(reloaded.cuts.count == 2,
                    "disk must hold both cuts, not whichever save happened to land last: \(reloaded.cuts)")
            #expect(reloaded.cuts == editor.currentEDLForTesting().cuts,
                    "disk and the editor's own EDL must not diverge")
        }
    }


    /// F9 (whole-branch review): autosave runs an unstructured `Task`, and
    /// nothing waited for it at termination — ⌘Q (or the status item's
    /// Quit) pressed immediately after a trim exited before `apply` +
    /// `persist` finished and silently lost the edit. With F1's gate in
    /// place this was the last remaining path by which a completed edit
    /// could disappear.
    ///
    /// `replyToTerminate` is substituted rather than letting the real
    /// `reply(toApplicationShouldTerminate:)` run: that call outside a real
    /// termination sequence is the one thing in this file that could take
    /// the test process down with it.
    @Test("Quitting straight after a trim waits for that trim to reach disk")
    func terminationFlushesAPendingSave() async throws {
        let url = try await makeFixtureBundle()
        defer { try? FileManager.default.removeItem(at: url) }

        try await EditorWindowTestGate.run {
            let controller = try await DocumentOpener.open(bundleURL: url)
            defer { controller.close() }

            let delegate = AppDelegate()
            var replies: [Bool] = []
            delegate.replyToTerminate = { replies.append($0) }

            // With nothing outstanding the ordinary quit must not wait —
            // a delegate that always answers `.terminateLater` makes every
            // quit depend on a reply arriving.
            #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)

            // Deliberately NOT awaited: this is the ⌘Q-straight-after-a-trim
            // case, with the save still in flight.
            controller.applyTrimForTesting(TimeRange(start: 1.0, end: 3.0))
            #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)

            await delegate.waitForTerminationFlushForTesting()
            #expect(replies == [true], "AppKit must be told to go ahead exactly once")

            let reloaded = try EditDecisionList.read(from: SnittBundle(opening: url))
            #expect(reloaded.cuts.count == 1,
                    "the trim must be on disk before termination is allowed to proceed")
        }
    }
}
