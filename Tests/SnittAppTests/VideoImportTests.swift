// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import AVFoundation
import Foundation
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// Opening a video Snitt did not record.
///
/// The feature in one line: after the import there is no difference between
/// this document and a recorded one, because the imported file IS the bundle's
/// `capture.mov`. So the tests are about the import being faithful — the
/// source untouched, the bundle complete, nothing in the recordings folder
/// until somebody saves.
@Suite(.serialized)
@MainActor
struct VideoImportTests {
    init() { _ = NSApplication.shared }

    private func sourceVideo(named name: String = "demo") async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        try await writeSyntheticMovie(to: url, seconds: 2.0)
        return url
    }

    @Test("An imported video becomes the bundle's capture, byte for byte")
    func importCopiesTheSource() async throws {
        let source = try await sourceVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let bundle = try await VideoImporter.makeBundle(from: source)
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        // Byte-identical, not re-encoded: an import that transcoded would lose
        // quality for nothing and take as long as an export.
        let original = try Data(contentsOf: source)
        let imported = try Data(contentsOf: bundle.captureURL)
        #expect(original == imported)
    }

    @Test("The source file is left where it was")
    func importDoesNotMoveTheSource() async throws {
        // Copied, never moved. Deleting somebody's file as a side effect of
        // opening it is not a thing an "open" may do.
        let source = try await sourceVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let bundle = try await VideoImporter.makeBundle(from: source)
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("The bundle is complete enough to open and edit")
    func importedBundleIsUsable() async throws {
        // Both sidecars, because the editor reads them on open and an import
        // missing either is a document that fails at the last step — after the
        // copy, which is the slow part.
        let source = try await sourceVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let bundle = try await VideoImporter.makeBundle(from: source)
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        #expect(FileManager.default.fileExists(atPath: bundle.editURL.path))
        let meta = try RecordingMetadata.read(from: bundle)
        #expect(meta.initiator == .human)
        #expect((meta.durationSeconds ?? 0) > 1.5, "the duration was not read from the media")

        // And it actually builds a composition, which is the only proof that
        // auto-trim, cutting and export will work on it.
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        #expect(built.composition.tracks(withMediaType: .video).count == 1)
    }

    @Test("An imported document lands in scratch, not in the recordings folder")
    func importDoesNotTouchTheRecordingsFolder() async throws {
        // An import nobody has saved is not a recording they decided to keep.
        // Writing it to `~/Documents/Snitt` would fill that folder with
        // documents indistinguishable from the ones they did.
        let source = try await sourceVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let bundle = try await VideoImporter.makeBundle(from: source)
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        let recordings = OutputDirectorySettings.load().directory.standardizedFileURL.path
        #expect(!bundle.url.standardizedFileURL.path.hasPrefix(recordings))
        #expect(bundle.url.path.hasPrefix(VideoImporter.scratchDirectory().path))
    }

    @Test("A file with no video track is refused, and says which problem it is")
    func audioOnlyIsRefusedDistinctly() async throws {
        // "Unreadable" and "no picture" need different remedies, and telling
        // somebody their file is corrupt when it is merely audio sends them to
        // fix the wrong thing.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID().uuidString).mov")
        try Data("not a movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: (any Error).self) {
            _ = try await VideoImporter.makeBundle(from: url)
        }
    }

    @Test("Two imports of the same filename do not collide")
    func repeatedImportsGetTheirOwnBundles() async throws {
        let source = try await sourceVideo(named: "same-name")
        defer { try? FileManager.default.removeItem(at: source) }
        let first = try await VideoImporter.makeBundle(from: source)
        defer { try? FileManager.default.removeItem(at: first.url) }
        let second = try await VideoImporter.makeBundle(from: source)
        defer { try? FileManager.default.removeItem(at: second.url) }
        #expect(first.url != second.url)
    }

    // MARK: - Drops and the clipboard

    @Test("A drag carrying a video is accepted; one carrying anything else is not")
    func dropTargetAgreesWithOpen() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("snitt.test.\(UUID().uuidString)"))
        board.clearContents()
        let video = FileManager.default.temporaryDirectory
            .appendingPathComponent("drop-\(UUID().uuidString).mp4")
        try Data([0]).write(to: video)
        defer { try? FileManager.default.removeItem(at: video) }
        board.writeObjects([video as NSURL])
        #expect(VideoDropTarget.accepts(board))
        #expect(VideoDropTarget.videos(in: board) == [video])

        board.clearContents()
        let text = FileManager.default.temporaryDirectory
            .appendingPathComponent("drop-\(UUID().uuidString).txt")
        try Data([0]).write(to: text)
        defer { try? FileManager.default.removeItem(at: text) }
        board.writeObjects([text as NSURL])
        #expect(!VideoDropTarget.accepts(board), "a text file was accepted as a video")
    }

    @Test("An empty clipboard offers no video rather than failing")
    func emptyClipboardIsSilent() {
        let board = NSPasteboard(name: NSPasteboard.Name("snitt.test.\(UUID().uuidString)"))
        board.clearContents()
        #expect(ClipboardMedia.video(in: board) == nil)
    }

    @Test("The clipboard reader finds the video among other items")
    func clipboardPicksTheVideo() throws {
        // A board holding a text file AND a movie should yield the movie, not
        // the first item — which is the shape a Finder multi-select produces.
        let board = NSPasteboard(name: NSPasteboard.Name("snitt.test.\(UUID().uuidString)"))
        board.clearContents()
        let text = FileManager.default.temporaryDirectory
            .appendingPathComponent("c-\(UUID().uuidString).txt")
        let video = FileManager.default.temporaryDirectory
            .appendingPathComponent("c-\(UUID().uuidString).mov")
        try Data([0]).write(to: text)
        try Data([0]).write(to: video)
        defer {
            try? FileManager.default.removeItem(at: text)
            try? FileManager.default.removeItem(at: video)
        }
        board.writeObjects([text as NSURL, video as NSURL])
        #expect(ClipboardMedia.video(in: board) == video)
    }
}

/// Saving an imported document, which is the only time ⌘S does anything.
///
/// A recording Snitt made is written to the recordings folder as it stops and
/// every edit since has been saved as it happened. An import lives in a
/// scratch directory until somebody says where it belongs.
@Suite(.serialized)
@MainActor
struct ImportedDocumentSaveTests {
    init() { _ = NSApplication.shared }

    /// Opens a real editor window, so every caller must run inside
    /// `EditorWindowTestGate` and close what it opened.
    ///
    /// `EditorWindowController.openWindowCount` is a process-global that
    /// `EditorWindowControllerTests` and `DockReopenTests` assert exact values
    /// against, and Swift Testing runs suites concurrently — so a window this
    /// suite opens can appear between their snapshot and their assertion. That
    /// is not hypothetical: leaving these ungated failed both of those suites
    /// on the first full run, with counts off by exactly the number of
    /// editors opened here.
    private func importedEditor() async throws -> EditorWindowController {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("save-\(UUID().uuidString).mov")
        try await writeSyntheticMovie(to: source, seconds: 1.5)
        defer { try? FileManager.default.removeItem(at: source) }
        return try await DocumentOpener.importVideo(at: source)
    }

    @Test("An imported document is unsaved; a recorded one is not")
    func onlyImportsAreUnsaved() async throws {
        try await EditorWindowTestGate.run {
            let editor = try await importedEditor()
            defer {
                editor.close()
                try? FileManager.default.removeItem(at: editor.bundleURL)
            }
            #expect(editor.isUnsaved)
        }
    }

    @Test("Saving moves the bundle and the window follows it")
    func savingRelocatesInPlace() async throws {
        // Relocated rather than reopened. Reopening would throw away undo
        // history and the playhead, and the document is identical before and
        // after — only its path changed.
        try await EditorWindowTestGate.run {
            let editor = try await importedEditor()
            let scratch = editor.bundleURL
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("saved-\(UUID().uuidString)")
                .appendingPathExtension(SnittBundle.fileExtension)
            defer {
                editor.close()
                try? FileManager.default.removeItem(at: destination)
            }

            try editor.relocate(to: destination)

            #expect(editor.bundleURL.standardizedFileURL == destination.standardizedFileURL)
            #expect(editor.isUnsaved == false, "it is still claiming to be unsaved")
            #expect(!FileManager.default.fileExists(atPath: scratch.path),
                    "the scratch copy was left behind")
            #expect(FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("capture.mov").path))
        }
    }

    @Test("Edits after a save land in the NEW location, not the scratch one")
    func laterEditsFollowTheMove() async throws {
        // The failure this exists for is silent: every write in this app is
        // fire-and-forget, so a preview still pointed at the scratch path
        // would write `edit.json` into a directory that no longer exists and
        // report nothing. The document would look fine until it was reopened.
        try await EditorWindowTestGate.run {
            let editor = try await importedEditor()
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("saved-\(UUID().uuidString)")
                .appendingPathExtension(SnittBundle.fileExtension)
            defer {
                editor.close()
                try? FileManager.default.removeItem(at: destination)
            }

            try editor.relocate(to: destination)
            #expect(editor.previewBundleURLForTesting.standardizedFileURL
                    == destination.standardizedFileURL,
                    "the preview is still writing to the scratch bundle")
        }
    }
}

/// The empty document, and where a drop is and is not accepted.
///
/// Scope, stated as a test: a drop is accepted by the APP (Dock icon, Finder
/// "Open With") and by an EMPTY document. An editor that already has video
/// does not take one, because splicing a second source into a `.snitt` needs
/// the document to become a sequence of clips — a different format, not a
/// bigger version of this one.
@Suite(.serialized)
@MainActor
struct EmptyDocumentTests {
    init() { _ = NSApplication.shared }

    @Test("File ▸ New with nothing to import opens ONE empty document")
    func newOpensOneEmptyDocument() {
        defer { EmptyDocumentWindow.resetForTesting() }
        EmptyDocumentWindow.show(onVideos: { _ in }, activate: false)
        #expect(EmptyDocumentWindow.open.count == 1)

        // A second ⌘N brings the first forward rather than stacking a
        // duplicate — two of these are indistinguishable, so the person would
        // be closing windows they never deliberately made.
        EmptyDocumentWindow.show(onVideos: { _ in }, activate: false)
        #expect(EmptyDocumentWindow.open.count == 1)
    }

    @Test("The app declares plain video, so a Dock drop reaches it")
    func theAppAcceptsVideoFiles() throws {
        // Without a CFBundleDocumentTypes entry for video, macOS does not
        // offer Snitt as a handler and a file dropped on the Dock icon bounces
        // — there is no code path to fail, so nothing would report it.
        let script = try String(contentsOfFile: "Scripts/make-app.sh", encoding: .utf8)
        #expect(script.contains("public.movie"), "make-app.sh declares no video type")
        // Viewer, not Editor: opening a video IMPORTS it, and Snitt never
        // writes back to somebody else's .mp4. Declaring Editor would offer
        // Snitt as a handler that owns the file, which it never becomes.
        #expect(script.contains("<key>CFBundleTypeRole</key><string>Viewer</string>"))
    }

    @Test("New from Clipboard is dead when the clipboard holds no video")
    func clipboardItemIsDisabledWithoutMedia() throws {
        // An item named for the clipboard that works without one has a title
        // that is not true, and the failure it produces — nothing happens — is
        // indistinguishable from a broken app.
        let delegate = AppDelegate()
        let item = NSMenuItem(title: "New from Clipboard",
                              action: #selector(AppDelegate.newDocument(_:)),
                              keyEquivalent: "")

        NSPasteboard.general.clearContents()
        #expect(delegate.validateMenuItem(item) == false)

        // And live again the moment a video is on the board. Asked at
        // validation time rather than cached, because the clipboard changes
        // while the app is running and AppKit calls this each time the menu
        // opens.
        let video = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString).mov")
        try Data([0]).write(to: video)
        defer {
            try? FileManager.default.removeItem(at: video)
            NSPasteboard.general.clearContents()
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([video as NSURL])
        #expect(delegate.validateMenuItem(item))
    }

    @Test("Empty New is a SEPARATE item, so it is reachable when the other is dead")
    func emptyNewHasItsOwnItem() throws {
        // The consequence of letting the clipboard item be disabled: it can no
        // longer be the only route to an empty document, because half the time
        // it is not a route at all.
        let file = try #require(AppShell.buildMainMenu().items
            .first { $0.title == "File" }?.submenu)
        let empty = try #require(file.items.first { $0.title == "New" },
                                 "File has no plain New item")
        #expect(empty.action == #selector(AppDelegate.newEmptyDocument(_:)))
        // Different key from the clipboard one, or one of them is unreachable.
        let clipboard = try #require(file.items.first { $0.title == "New from Clipboard" })
        #expect(empty.keyEquivalentModifierMask != clipboard.keyEquivalentModifierMask)
        // ⌘N stays on the clipboard item, as Preview binds it.
        #expect(clipboard.keyEquivalent == "n")
        #expect(clipboard.keyEquivalentModifierMask == [.command])
    }

    @Test("New from Clipboard carries the symbol Preview uses for the same command")
    func newFromClipboardMatchesPreview() throws {
        // Read out of `Preview.app`'s MainMenu nib, where `document.on.clipboard`
        // sits immediately beside the string "New from Clipboard" — not guessed
        // from the glyph. `doc.on.clipboard` also exists and is the older
        // spelling, so both resolve and picking the wrong one is a difference
        // nobody notices until the two apps are side by side.
        let file = try #require(AppShell.buildMainMenu().items
            .first { $0.title == "File" }?.submenu)
        let item = try #require(file.items.first { $0.title == "New from Clipboard" })
        #expect(item.image != nil, "the menu item has no icon")
        #expect(AppShell.newFromClipboardSymbol == "document.on.clipboard")
        // And it actually resolves on this system. A symbol name that does not
        // is not an error — `NSImage(systemSymbolName:)` returns nil and the
        // item simply renders without an icon.
        #expect(NSImage(systemSymbolName: AppShell.newFromClipboardSymbol,
                        accessibilityDescription: nil) != nil)
    }

    @Test("An editor showing video does NOT accept a dropped video")
    func editorsWithVideoRefuseDrops() throws {
        // The scope line, asserted rather than left to a comment. A drop that
        // landed here would have to splice into a document whose cuts,
        // markers, transcript, clicks and voiceover are all positions in ONE
        // source timeline — so it would either do nothing or do something
        // wrong, and both are worse than declining the drag.
        let source = try String(contentsOfFile: "Sources/SnittApp/EditorWindowController.swift",
                                encoding: .utf8)
        #expect(!source.contains("VideoDropOverlay"),
                "the editor accepts video drops, which the document model cannot honour")
    }
}
