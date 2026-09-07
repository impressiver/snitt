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

        // Every test in this file that reads `openWindowCount` around a
        // `before`/`after` snapshot runs inside `EditorWindowTestGate`
        // (Task 7). `.serialized` only serializes tests WITHIN this suite;
        // `EditorWindowControllerTests` and `EditorPersistenceTests` are
        // independently-serialized suites that swift-testing runs
        // concurrently with this one, and all three open real windows and
        // read this same process-global counter. Without the gate, a
        // window opened by one of those suites can land inside this test's
        // snapshot-to-assertion window and make the count wrong for a
        // reason that has nothing to do with `DocumentOpener`.
        try await EditorWindowTestGate.run {
            let before = EditorWindowController.openWindowCount
            let controller = try await DocumentOpener.open(bundleURL: url)
            defer { controller.close() }

            // Assert the OUTCOME — a window exists — not that a function was
            // called. "openEditor was invoked" passes against an implementation
            // that throws inside and swallows it.
            #expect(EditorWindowController.openWindowCount == before + 1)
            #expect(controller.window.title == url.lastPathComponent)
        }
    }

    @Test("Opening a path that is not a directory throws SnittBundleError.notADirectory rather than opening an empty window")
    func rejectsNonBundle() async throws {
        let junk = FileManager.default.temporaryDirectory
            .appending(path: "not-a-bundle-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }

        try await EditorWindowTestGate.run {
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

        try await EditorWindowTestGate.run {
            let before = EditorWindowController.openWindowCount
            await #expect(throws: CocoaError.self) {
                _ = try await DocumentOpener.open(bundleURL: empty)
            }
            #expect(EditorWindowController.openWindowCount == before)
        }
    }

    @Test("Opening a bundle whose edit.json declares a future schemaVersion throws rather than silently opening with an empty EDL")
    func rejectsFutureSchemaVersionRatherThanSilentlyDefaulting() async throws {
        // D60/M5f: `build(bundle:)` used to read edit.json with `(try?
        // EditDecisionList.read(from: bundle)) ?? .fullRange()` — the same
        // collapsing pattern a whole-branch review already fixed at the
        // CLI's two `AutomationHost` call sites
        // (`TrimAndExportHostTests.exportWithCorruptEDLFailsExplicitly`/
        // `trimWithCorruptEDLFailsExplicitly`), left standing here. A
        // `schemaVersion` newer than this build understands is a real
        // edit.json that EXISTS and fails to decode — collapsing that into
        // `.fullRange()` would silently show an EMPTY timeline for a
        // recording a newer Snitt build had already trimmed, and the next
        // autosave would overwrite edit.json with that empty EDL,
        // destroying the newer build's cuts permanently. Updates are
        // hand-delivered (D54), so an old and a new build coexisting on
        // one machine is not a hypothetical.
        let url = try await makeFixtureBundle()
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = try SnittBundle(opening: url)
        try Data(#"{"schemaVersion":99,"cuts":[],"trackStates":[]}"#.utf8).write(to: bundle.editURL)

        try await EditorWindowTestGate.run {
            let before = EditorWindowController.openWindowCount
            await #expect(throws: EditDecisionListError.self) {
                _ = try await DocumentOpener.open(bundleURL: url)
            }
            #expect(EditorWindowController.openWindowCount == before,
                    "a future-schemaVersion edit.json must not open a window at all, let alone an empty one")
        }
    }

    @Test("Opening a bundle whose events.json declares a future schemaVersion throws rather than silently opening with an empty marker list")
    func rejectsFutureEventsSchemaVersionRatherThanSilentlyDroppingMarkers() async throws {
        // D60/M5f Task 7: the events.json sibling of
        // `rejectsFutureSchemaVersionRatherThanSilentlyDefaulting` above.
        // `EventLog.schemaVersion` was bumped 1 -> 2 by Task 6 with no such
        // guard — `build(bundle:)` calls `EventLog.read(from: bundle)`
        // directly (no `try?`), so this was never a SILENT collapse the way
        // `edit.json`'s was, but until `EventLog.init(from:)` gained this
        // gate, a newer build's `events.json` decoded ONLY the fields an
        // older build recognizes and silently dropped `transcript` — the
        // only place a marker's narration lives — with the very next
        // autosave making that loss permanent. This pins the refusal at the
        // GUI's open path specifically, not just at the bare decoder.
        let url = try await makeFixtureBundle()
        defer { try? FileManager.default.removeItem(at: url) }
        let bundle = try SnittBundle(opening: url)
        try Data(#"{"schemaVersion":99,"events":[]}"#.utf8).write(to: bundle.eventsURL)

        try await EditorWindowTestGate.run {
            let before = EditorWindowController.openWindowCount
            await #expect(throws: EventLogError.self) {
                _ = try await DocumentOpener.open(bundleURL: url)
            }
            #expect(EditorWindowController.openWindowCount == before,
                    "a future-schemaVersion events.json must not open a window at all, let alone an empty one")
        }
    }

    @Test("Opening a bundle records it in the recent documents list")
    func openingNotesARecentDocument() async throws {
        let url = try await makeFixtureBundle()
        defer {
            try? FileManager.default.removeItem(at: url)
            // NSDocumentController's recents list is real per-process state
            // (§ "Do not pollute the maintainer's real recents list"); leave
            // it as we found it rather than accumulating fixture URLs across
            // test runs.
            NSDocumentController.shared.clearRecentDocuments(nil)
        }

        try await EditorWindowTestGate.run {
            let controller = try await DocumentOpener.open(bundleURL: url)
            defer { controller.close() }

            // The observable outcome, not "note() was called": a menu built after
            // opening must contain the document. Resolved against symlinks: the
            // fixture lives under `/tmp`, which macOS reports back through
            // `NSDocumentController` as `/private/tmp` — a path difference, not
            // a different document.
            let resolvedRecents = RecentDocuments.urls().map { $0.resolvingSymlinksInPath() }
            #expect(resolvedRecents.contains(url.resolvingSymlinksInPath()))
        }
    }

    // MARK: - Task 6: one window per document

    @Test("Two different bundles open two independent windows")
    func twoBundlesOpenTwoWindows() async throws {
        let a = try await makeFixtureBundle()
        let b = try await makeFixtureBundle()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }

        try await EditorWindowTestGate.run {
            let before = EditorWindowController.openWindowCount
            let first = try await DocumentOpener.open(bundleURL: a)
            let second = try await DocumentOpener.open(bundleURL: b)
            defer { first.close(); second.close() }

            #expect(EditorWindowController.openWindowCount == before + 2)
            #expect(first.window !== second.window)
        }
    }

    @Test("Opening the same bundle twice focuses the existing window instead of duplicating it")
    func sameBundleReusesItsWindow() async throws {
        let url = try await makeFixtureBundle()
        defer { try? FileManager.default.removeItem(at: url) }

        try await EditorWindowTestGate.run {
            let first = try await DocumentOpener.open(bundleURL: url)
            defer { first.close() }
            let before = EditorWindowController.openWindowCount
            let second = try await DocumentOpener.open(bundleURL: url)

            // Two windows on one document means two EDLs over one bundle, and
            // whichever saves last wins — a data-loss shape, not a cosmetic one.
            #expect(EditorWindowController.openWindowCount == before)
            #expect(first.window === second.window)
        }
    }

    @Test("Opening the same bundle via /tmp and /private/tmp still reuses the window")
    func sameBundleReusesItsWindowAcrossSymlinkSpellings() async throws {
        // On macOS `/tmp` is a symlink to `/private/tmp`. A raw string
        // comparison of URLs would see two different paths here and open a
        // second window on the same document — exactly the data-loss shape
        // `EditorWindowController.existing(for:)` exists to prevent. This is
        // the mutation Task 6's brief calls out by name: comparing raw
        // `url` strings instead of standardized ones must fail THIS test,
        // even though `sameBundleReusesItsWindow` above (same-spelling) can
        // still pass against that mutant.
        //
        // Deliberately NOT built via `makeFixtureBundle()`:
        // `FileManager.default.temporaryDirectory` on macOS resolves to
        // `/var/folders/...`, not `/tmp`, so this test builds the fixture
        // directly under the literal `/tmp` path the mutation names.
        let tmpSpelling = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("fixture-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: tmpSpelling)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 1)
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)
        try EventLog(events: []).write(to: bundle)
        try EditDecisionList.fullRange().write(to: bundle)
        defer { try? FileManager.default.removeItem(at: tmpSpelling) }

        let privateTmpSpelling = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent(tmpSpelling.lastPathComponent)
        #expect(tmpSpelling.path != privateTmpSpelling.path)

        try await EditorWindowTestGate.run {
            let first = try await DocumentOpener.open(bundleURL: tmpSpelling)
            defer { first.close() }
            let before = EditorWindowController.openWindowCount
            let second = try await DocumentOpener.open(bundleURL: privateTmpSpelling)

            #expect(EditorWindowController.openWindowCount == before)
            #expect(first.window === second.window)
        }
    }

    /// F3 (whole-branch review): the dedup check runs BEFORE
    /// `await CompositionBuilder.build`, but a controller only joins the
    /// registry inside `show()` — after the build. Two opens of one bundle
    /// issued while the first build is in flight therefore both pass the
    /// check and both show a window: two windows, two EDLs, last-save-wins.
    /// That is the same data loss `sameBundleReusesItsWindow` above exists
    /// to prevent, arriving through a door every sequential `await` in this
    /// suite steps over. Reachable in the wild by a second Finder
    /// double-click during a multi-second build of a long recording.
    ///
    /// `async let` is what makes this deterministic rather than a race:
    /// the first open runs on the main actor until it suspends inside the
    /// composition build, which is exactly when the second open gets to run
    /// its own `existing(for:)` check against a registry nothing has joined
    /// yet.
    @Test("Two opens of one bundle issued during the same build produce one window")
    func concurrentOpensOfOneBundleShareOneWindow() async throws {
        let url = try await makeFixtureBundle()
        defer { try? FileManager.default.removeItem(at: url) }

        try await EditorWindowTestGate.run {
            let before = EditorWindowController.openWindowCount
            async let first = DocumentOpener.open(bundleURL: url)
            async let second = DocumentOpener.open(bundleURL: url)
            let (a, b) = try await (first, second)
            defer { a.close(); b.close() }

            #expect(EditorWindowController.openWindowCount == before + 1,
                    "a second open during the first one's build must join it, not open a second window")
            #expect(a === b)
        }
    }
}
