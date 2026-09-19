// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
import SnittAutomation
import SnittDocument
@testable import SnittApp

/// D108 at the seam: the host lists the directory Snitt actually writes to,
/// and the watchdog leaves a mark on what it force-stopped.
///
/// `RecordingInventoryTests` covers the listing logic itself. These cover the
/// two things only the app can do: point it at the right directory, and stamp
/// a bundle with how its session ended.
@Suite
struct RecordingListingTests {

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "listing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func host(directory: URL, agentAccess: Bool = true) -> AutomationHost {
        AutomationHost(coordinator: FakeCoordinator(),
                       settings: { AgentSettings(agentRecordingEnabled: agentAccess) },
                       onRecordingState: { _ in },
                       auditLogURL: FileManager.default.temporaryDirectory
                           .appending(path: "listing-audit-\(UUID().uuidString).jsonl"),
                       outputDirectory: { directory })
    }

    @MainActor
    @Test("The listing reads the output directory, and says which one")
    func listsTheOutputDirectory() async throws {
        // DISCRIMINATES AGAINST: capturing `OutputDirectorySettings.load()`
        // once at construction, or hardcoding the default. The setting is
        // user-configurable and `main.swift` already notes that the
        // coordinator re-reads it FRESH for exactly this reason; a captured
        // value lists a directory Snitt has stopped writing to, and reports
        // "no recordings" about a disk that is filling up.
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try SnittBundle(creatingAt: directory.appending(path: "demo.snitt"))
        try RecordingMetadata(createdAt: Date(), initiator: .agent).write(to: bundle)

        let response = await host(directory: directory).handle(.listRecordings(limit: nil),
                                                               caller: nil)
        guard case .recordings(let list) = response else {
            Issue.record("expected a listing, got \(response)"); return
        }
        #expect(list.total == 1)
        #expect(list.directory == directory.path)
    }

    @MainActor
    @Test("Listing recordings is an agent-access verb")
    func listingIsGated() async throws {
        // A bundle's FILENAME is derived from the git branch and commit
        // (`BundleNaming`), which is why `RecordingCoordinator` redacts it
        // from its own log lines: a branch called
        // `feat/acme-corp-integration` names a customer or an unreleased
        // feature. Listing the directory hands those out wholesale, to any
        // same-user process the socket accepts.
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let response = await host(directory: directory, agentAccess: false)
            .handle(.listRecordings(limit: nil), caller: nil)
        guard case .failure(let error) = response else {
            Issue.record("the directory was listed with agent access off"); return
        }
        #expect(error.code == .consentRequired)
    }
}
