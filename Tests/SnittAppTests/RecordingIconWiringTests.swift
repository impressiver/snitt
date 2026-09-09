// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import Foundation
import Testing
@testable import SnittApp
@testable import SnittDocument
@testable import SnittExport

/// The Finder icon has to be refreshed when editing changes what the
/// recording is.
///
/// `RecordingIcon`'s own tests prove it can compose and stamp an icon. These
/// prove the app actually asks it to — the failure this project keeps
/// repeating is a working mechanism nobody wired up, most recently a
/// launch-on-demand path whose unit tests all passed while the real binary
/// never fired.
///
/// The poster is drawn from the material the EDL KEEPS, so a trim can leave
/// the icon showing seconds that are no longer in the recording. Refreshing
/// happens on close rather than per edit because stamping a real capture takes
/// roughly half a second.
@Suite(.serialized)
@MainActor
struct RecordingIconWiringTests {
    init() { _ = NSApplication.shared }

    private func makeBundle() async throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "icon-wiring-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 3.0)
        try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)
        try EventLog(events: []).write(to: bundle)
        try EditDecisionList.fullRange().write(to: bundle)
        return root
    }

    /// The custom icon for a package is a file named `Icon\r` inside it.
    private func iconURL(_ root: URL) -> URL { root.appending(path: "Icon\r") }

    private func waitForIcon(_ root: URL, timeout: Double) async -> Bool {
        var waited = 0.0
        while waited < timeout {
            if FileManager.default.fileExists(atPath: iconURL(root).path) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 0.05
        }
        return false
    }

    @Test("Closing an editor after a cut refreshes the recording's icon")
    func editingRefreshesTheIcon() async throws {
        try await EditorWindowTestGate.run {
            let root = try await makeBundle()
            defer { try? FileManager.default.removeItem(at: root) }
            let controller = try await DocumentOpener.open(bundleURL: root)

            #expect(FileManager.default.fileExists(atPath: iconURL(root).path) == false,
                    "the bundle should start with no custom icon")

            controller.selectForTesting(TimeRange(start: 0, end: 1))
            controller.cutTimelineSelection()
            // Let the cut's save land — it applies on a detached task, and the
            // flag the close reads is set by that save, not by the cut.
            var waited = 0.0
            while controller.currentEDLForTesting().cuts.isEmpty, waited < 5 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                waited += 0.02
            }
            #expect(controller.currentEDLForTesting().cuts.isEmpty == false,
                    "the cut never landed, so this proves nothing about the icon")

            controller.close()
            #expect(await waitForIcon(root, timeout: 20),
                    "closing an edited recording did not refresh its icon")
        }
    }

    @Test("Closing an editor that changed nothing does not restamp")
    func openingAndClosingDoesNotStamp() async throws {
        try await EditorWindowTestGate.run {
            let root = try await makeBundle()
            defer { try? FileManager.default.removeItem(at: root) }
            let controller = try await DocumentOpener.open(bundleURL: root)
            controller.close()

            // The positive case above lands well inside this window, so a
            // stamp firing unconditionally would be seen here. Without this,
            // "refresh on edit" passes against "refresh on every close" —
            // which would run a half-second job every time a window shuts.
            #expect(await waitForIcon(root, timeout: 6) == false,
                    "an unedited recording was restamped on close")
        }
    }
}
