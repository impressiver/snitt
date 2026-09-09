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

/// Task 8: the missing half of record → trim → share. Before this task,
/// `EditorWindowController` had no export path at all (reachable only over
/// the CLI/MCP `AutomationHost`), and `RecordingCoordinator`'s stop-time
/// clipboard copy — the raw, untrimmed `capture.mov` — was never superseded,
/// so a person who trimmed and pasted shipped the wrong file with no error
/// anywhere.
///
/// `.serialized`, and every test body runs inside `EditorWindowTestGate`
/// (Task 7's cross-suite gate): these tests open a real, real front-ordered
/// `NSWindow` through `DocumentOpener.open`, exactly like
/// `DocumentOpenerTests`, `EditorWindowControllerTests`, and
/// `EditorPersistenceTests` — all three independently-serialized suites
/// swift-testing runs concurrently with this one against the SAME
/// process-global `EditorWindowController.openWindowCount`.
@Suite(.serialized)
@MainActor
struct EditorExportTests {
    init() { _ = NSApplication.shared }

    /// 12s of media — long enough that a 3-second cut (1.0–4.0) leaves an
    /// unambiguous, easily-measured difference from the source duration
    /// without brushing up against encoder frame-duration rounding at the
    /// margin.
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

    @Test("Exporting writes a file whose duration reflects the trim")
    func exportHonoursTheTrim() async throws {
        let url = try await makeFixtureBundle()
        defer { try? FileManager.default.removeItem(at: url) }

        try await EditorWindowTestGate.run {
            let controller = try await DocumentOpener.open(bundleURL: url)
            defer { controller.close() }

            controller.applyTrimForTesting(TimeRange(start: 1.0, end: 4.0))
            let out = FileManager.default.temporaryDirectory
                .appending(path: "export-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: out) }

            // A throwaway pasteboard — this test cares about the exported
            // file's duration, not the clipboard, and must not disturb
            // whatever is really on the machine's clipboard.
            let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
            try await controller.exportForTesting(to: out, pasteboard: pasteboard)

            // Assert the DURATION, not that a file exists. An export that
            // ignored the EDL still produces a file, and file-exists passes
            // against exactly the bug this task exists to fix.
            let asset = AVURLAsset(url: out)
            let seconds = try await asset.load(.duration).seconds
            let source = try await AVURLAsset(url: SnittBundle(opening: url).captureURL)
                .load(.duration).seconds
            #expect(seconds < source - 1.5,
                    "a 3-second cut out of \(source)s must leave the export meaningfully shorter, not \(seconds)s")
        }
    }

    @Test("Exporting supersedes the stale stop-time clipboard copy")
    func exportRecopies() async throws {
        let url = try await makeFixtureBundle()
        defer { try? FileManager.default.removeItem(at: url) }

        try await EditorWindowTestGate.run {
            let controller = try await DocumentOpener.open(bundleURL: url)
            defer { controller.close() }

            let out = FileManager.default.temporaryDirectory
                .appending(path: "export-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: out) }

            let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
            // Simulate `RecordingCoordinator.stopRecording()`'s stop-time
            // copy of the RAW `capture.mov`, which happens before the
            // editor even opens. This is the stale state export must
            // supersede — without it, this test could pass merely because
            // the pasteboard started empty.
            let bundle = try SnittBundle(opening: url)
            #expect(ClipboardDestination.copy(fileURL: bundle.captureURL, to: pasteboard))

            try await controller.exportForTesting(to: out, pasteboard: pasteboard)

            // Assert the pasteboard holds the EXPORT, not `captureURL` —
            // Task 8's second defect, and the one that fails silently in
            // the user's hands.
            let read = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
            #expect(read?.first?.lastPathComponent == out.lastPathComponent,
                    "the clipboard must hold the trimmed export, not the stale raw capture")
        }
    }
}
