// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
import AppKit
import SnittDocument
@testable import SnittApp
@testable import SnittExport

/// An open editor and a bundle that changed underneath it.
///
/// W7 made the window the one writer for a recording and routed agent edits
/// into it. That is still right, and it never covered everything else that can
/// write a sidecar: a person in a text editor, a script, another machine. The
/// window did not notice, and had to be closed and reopened before it would
/// re-read — "point it at another bundle and back" was the workaround people
/// actually used.
@Suite(.serialized)
@MainActor
struct StaleEditorTests {
    init() { _ = NSApplication.shared }

    private func makeState(seconds: Double = 6.0)
    async throws -> (EditorTimelineState, SnittBundle) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: seconds)
        try EditDecisionList.fullRange().write(to: bundle)
        try EventLog(events: []).write(to: bundle)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        return (EditorTimelineState(controller: controller,
                                    edl: .fullRange(), events: []), bundle)
    }

    private func marker(_ label: String, at seconds: Double) -> LoggedEvent {
        LoggedEvent(id: UUID(), timeSeconds: seconds, kind: .marker, label: label)
    }

    @Test("A marker added to events.json underneath the window shows up")
    func externalMarkersAreAdopted() async throws {
        // THE REPORTED BUG, end to end: something edits events.json while the
        // editor is open, and the editor goes on showing what it read when it
        // opened. Verified to fail by removing the `reconcileWithDisk` call.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        #expect(state.events.isEmpty)

        try EventLog(events: [marker("added by someone else", at: 2)]).write(to: bundle)
        state.reconcileWithDisk()

        #expect(state.events.count == 1, "the external marker never arrived")
        #expect(state.events.first?.label == "added by someone else")
    }

    @Test("A marker REMOVED from events.json disappears from the window")
    func externalRemovalsAreAdopted() async throws {
        // The direction the reported session actually hit: a "Screenshot"
        // marker deleted out of events.json by hand, still listed in the
        // editor. A reconciliation that only ever merged in additions would
        // pass the test above and still fail this.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        try EventLog(events: [marker("Screenshot", at: 1)]).write(to: bundle)
        state.reconcileWithDisk()
        #expect(state.events.count == 1)

        try EventLog(events: []).write(to: bundle)
        state.reconcileWithDisk()
        #expect(state.events.isEmpty, "the deleted marker is still on screen")
    }

    @Test("A cut written to edit.json underneath the window is adopted")
    func externalCutsAreAdopted() async throws {
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        #expect(state.edl.cuts.isEmpty)

        var edited = EditDecisionList.fullRange()
        edited.cuts = [Cut(range: TimeRange(start: 1, end: 2))]
        try edited.write(to: bundle)
        state.reconcileWithDisk()
        await state.waitForPendingSave()

        #expect(state.edl.cuts.count == 1, "the external cut never arrived")
    }

    @Test("Adopting does not write the file back")
    func adoptingIsNotAuthorship() async throws {
        // Reading someone else's edit must not make this window its author.
        // `applyAndSave` would rebuild AND persist, rewriting the file just
        // read — harmless-looking until two writers start trading saves.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        var edited = EditDecisionList.fullRange()
        edited.cuts = [Cut(range: TimeRange(start: 1, end: 2))]
        try edited.write(to: bundle)
        let written = try Data(contentsOf: bundle.editURL)

        state.reconcileWithDisk()
        await state.waitForPendingSave()

        #expect(try Data(contentsOf: bundle.editURL) == written,
                "adopting rewrote edit.json, making this window the author")
    }

    @Test("Unsaved work is never silently replaced")
    func unsavedWorkSurvives() async throws {
        // W7's data loss from the other direction. The window holds an edit
        // that is applied but not yet persisted; adopting over it would destroy
        // that with no error and no trace.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.setUnsavedEventsForTesting([marker("mine, unsaved", at: 3)])

        try EventLog(events: [marker("theirs, on disk", at: 4)]).write(to: bundle)

        var asked = false
        state.onDiskConflict = { answer in asked = true; answer(false) }
        state.reconcileWithDisk()

        #expect(asked, "the window replaced unsaved work without asking")
        #expect(state.events.first?.label == "mine, unsaved",
                "unsaved work was discarded")
    }

    @Test("Answering the conflict with reload takes the disk version")
    func reloadingOnConflictAdopts() async throws {
        // The other half: the prompt has to actually do something. A hook that
        // was asked and then ignored would pass the test above.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.setUnsavedEventsForTesting([marker("mine, unsaved", at: 3)])
        try EventLog(events: [marker("theirs, on disk", at: 4)]).write(to: bundle)

        state.onDiskConflict = { answer in answer(true) }
        state.reconcileWithDisk()

        #expect(state.events.first?.label == "theirs, on disk")
    }

    @Test("A save in flight defers the decision instead of asking about it")
    func aSaveInFlightIsNotAConflict() async throws {
        // What actually hung the suite. While a save is in flight `live` has
        // moved and `lastSaved` has not, so every comparison reads as a
        // conflict with ourselves — and the window asked. In the test suite,
        // where fixtures write sidecars while saves are settling, that was the
        // common case, and it put a dialog on screen waiting for a person who
        // was not there.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        var asked = false
        state.onDiskConflict = { answer in asked = true; answer(false) }

        // A real edit, so a save really is outstanding.
        state.addMarker(atOutput: 1.0)
        #expect(state.outstandingSaves > 0, "the fixture did not actually start a save")
        state.reconcileWithDisk()
        #expect(!asked, "asked about a conflict with a save still in flight")

        // And once it settles, the deferred pass runs on real values.
        await state.waitForPendingSave()
    }

    @Test("Nothing external happening leaves the window alone")
    func quiescenceChangesNothing() async throws {
        // THE CONTROL. The watcher fires on plenty of writes — including this
        // window's own saves — and a reconciliation that rebuilt the
        // composition every time would make an idle editor thrash, and would
        // make the tests above pass for the wrong reason.
        let (state, bundle) = try await makeState()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        state.setUnsavedEventsForTesting([marker("mine", at: 1)])
        state.reconcileWithDisk()
        var asked = false
        state.onDiskConflict = { answer in asked = true; answer(false) }
        state.reconcileWithDisk()

        #expect(asked, "an unsaved edit against an unchanged disk must still conflict")
    }
}

/// The watcher itself, as opposed to the reconciliation it drives.
///
/// Separated because the suite above calls `reconcileWithDisk()` directly, and
/// would pass in full against a watcher that never fired — the bug would then
/// be exactly as reported, with every test green.
@Suite(.serialized)
@MainActor
struct BundleWatcherTests {

    /// Polls rather than sleeping. A fixed delay is a flake this project has
    /// already paid for, and the deadline only binds when something is wrong.
    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("An EXISTING file rewritten in place reaches the window")
    func anInPlaceRewriteFires() async throws {
        // THE ONE THAT MATTERED, and the one the first version of this test
        // missed. It created a new file, which changes a DIRECTORY ENTRY — and
        // a `DispatchSource` on the directory's vnode sees exactly that and
        // nothing else. Against a real edit, which rewrites an existing
        // events.json in place, it never fired: green test, editor as stale as
        // before. Verified by running the real app, not by reading the code.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("events.json")
        try Data(#"{"events":[]}"#.utf8).write(to: file)

        let fired = Counter()
        let watcher = try #require(
            BundleWatcher(directory: directory, debounce: 0.05) { fired.bump() })
        defer { watcher.stop() }

        // Truncate-and-write, NOT an atomic replace: the shape a text editor,
        // a `>` redirect and most scripts produce.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(#"{"events":[{"kind":"marker"}]}"#.utf8))
        try handle.close()

        #expect(await waitUntil { fired.value > 0 },
                "an in-place rewrite did not reach the watcher")
    }

    @Test("An atomically replaced file reaches the window too")
    func anAtomicReplaceFires() async throws {
        // The other shape, which Snitt's own writes use. Both must work: the
        // fix for one must not lose the other.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("edit.json")
        try Data(#"{"cuts":[]}"#.utf8).write(to: file)

        let fired = Counter()
        let watcher = try #require(
            BundleWatcher(directory: directory, debounce: 0.05) { fired.bump() })
        defer { watcher.stop() }

        try Data(#"{"cuts":[{"x":1}]}"#.utf8).write(to: file, options: .atomic)
        #expect(await waitUntil { fired.value > 0 }, "an atomic replace did not fire")
    }

    @Test("A burst of writes is coalesced into one pass")
    func writesAreDebounced() async throws {
        // Saving a recording rewrites several sidecars in quick succession.
        // Reconciling once per file would read a bundle halfway through being
        // written, and would rebuild the composition several times over.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fired = Counter()
        let watcher = try #require(
            BundleWatcher(directory: directory, debounce: 0.3) { fired.bump() })
        defer { watcher.stop() }

        for name in ["edit.json", "events.json", "meta.json", "transcript.json"] {
            try Data("{}".utf8).write(to: directory.appendingPathComponent(name))
        }
        #expect(await waitUntil { fired.value > 0 })
        // Settle well past the latency, then check the burst did not become a
        // storm. Not `== 1`: with NoDefer the first event is delivered at once
        // and the rest coalesce, so two passes is correct, not a defect.
        try? await Task.sleep(for: .milliseconds(900))
        #expect(fired.value <= 3, "four writes produced \(fired.value) passes")
    }
}

/// Counts callbacks arriving from the watcher's own queue.
private final class Counter: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func bump() { lock.lock(); count += 1; lock.unlock() }
}
