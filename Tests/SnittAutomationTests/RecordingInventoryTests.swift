// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittAutomation
import SnittDocument

/// D108: an agent that crashed twice has two full-resolution videos it cannot
/// find. This is the listing that finds them.
@Suite
struct RecordingInventoryTests {

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "inventory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func recording(in directory: URL, named name: String,
                           createdAt: Date, initiator: Initiator = .agent,
                           outcome: String? = nil, bytes: Int = 0) throws -> URL {
        let bundle = try SnittBundle(creatingAt: directory.appending(path: "\(name).snitt"))
        try RecordingMetadata(createdAt: createdAt, initiator: initiator,
                              durationSeconds: 12, outcome: outcome).write(to: bundle)
        if bytes > 0 {
            try Data(repeating: 0, count: bytes).write(to: bundle.captureURL)
        }
        return bundle.url
    }

    @Test("Bundles come back newest first, with their age and their size")
    func listsNewestFirst() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        try recording(in: directory, named: "older", createdAt: now.addingTimeInterval(-7200))
        try recording(in: directory, named: "newer", createdAt: now.addingTimeInterval(-60),
                      bytes: 2_000_000)

        let list = RecordingInventory.list(in: directory, now: now)
        #expect(list.total == 2)
        #expect(list.recordings.first?.path.hasSuffix("newer.snitt") == true)
        #expect((list.recordings.first?.ageSeconds ?? 0) >= 59)
        // The whole bundle, not just the movie: meta.json is in there too, so
        // this is above the two megabytes written into capture.mov.
        #expect((list.recordings.first?.byteSize ?? 0) > 2_000_000)
        #expect(list.totalByteSize > 2_000_000)
    }

    @Test("A capped recording says it was capped")
    func cappedIsVisible() throws {
        // DISCRIMINATES AGAINST: a listing built from the filesystem alone
        // (path, size, mtime). A capped bundle is finalised by exactly the
        // same code as a clean stop, so nothing on disk distinguishes them
        // without `meta.json`'s outcome. Reporting only what `stat` knows
        // would list an agent's debris beside its finished work and give a
        // caller no way to tell which is which, which is the finding this
        // closes rather than a cosmetic omission.
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        try recording(in: directory, named: "abandoned", createdAt: now, outcome: "capped")
        try recording(in: directory, named: "finished", createdAt: now.addingTimeInterval(-10),
                      outcome: "completed")
        try recording(in: directory, named: "hotkey", createdAt: now.addingTimeInterval(-20),
                      initiator: .human)

        let list = RecordingInventory.list(in: directory, now: now)
        let byName = Dictionary(uniqueKeysWithValues:
            list.recordings.map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0) })
        #expect(byName["abandoned.snitt"]?.outcome == "capped")
        #expect(byName["finished.snitt"]?.outcome == "completed")
        // A person's own hotkey recording never passes through the agent API,
        // so it has no outcome to report, and `initiator` is what says so.
        #expect(byName["hotkey.snitt"]?.outcome == nil)
        #expect(byName["hotkey.snitt"]?.initiator == "human")
    }

    @Test("A limit truncates the list and says the list was truncated")
    func limitReportsTheTotal() throws {
        // DISCRIMINATES AGAINST: returning only the trimmed array. A caller
        // that got two of five and was told "two" concludes it has seen the
        // whole directory, which is exactly the wrong conclusion to reach
        // before deciding what to delete. `total` and `totalByteSize` are
        // computed before the truncation for that reason.
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        for index in 0..<5 {
            try recording(in: directory, named: "r\(index)",
                          createdAt: now.addingTimeInterval(Double(-index * 60)),
                          bytes: 1000)
        }

        let list = RecordingInventory.list(in: directory, now: now, limit: 2)
        #expect(list.recordings.count == 2)
        #expect(list.total == 5)
        #expect(list.totalByteSize > 5000, "the byte total shrank to the listed rows")
        #expect(list.recordings.first?.path.hasSuffix("r0.snitt") == true)
    }

    @Test("One damaged bundle does not hide the other recordings")
    func adamagedBundleIsSkipped() throws {
        // DISCRIMINATES AGAINST: `try RecordingMetadata.read(...)` propagating,
        // which is what the rest of this codebase does for a NAMED bundle and
        // is wrong for a directory listing: one unreadable `meta.json` would
        // make every other recording unfindable, and finding them is the whole
        // point. The count still reflects only what could be read.
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        try recording(in: directory, named: "good", createdAt: now)
        let broken = try SnittBundle(creatingAt: directory.appending(path: "broken.snitt"))
        try Data("not json".utf8).write(to: broken.metaURL)

        let list = RecordingInventory.list(in: directory, now: now)
        #expect(list.total == 1)
        #expect(list.recordings.first?.path.hasSuffix("good.snitt") == true)
    }

    @Test("Anything that is not a .snitt bundle is left alone")
    func onlyBundlesAreListed() throws {
        // The output directory is somebody's own folder and may be pointed at
        // one that holds other things. Listing a stray file as a recording
        // would be a claim about somebody's documents that is simply untrue.
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("hello".utf8).write(to: directory.appending(path: "notes.txt"))
        try FileManager.default.createDirectory(
            at: directory.appending(path: "Photos"), withIntermediateDirectories: true)
        try recording(in: directory, named: "real", createdAt: Date())

        #expect(RecordingInventory.list(in: directory).total == 1)
    }

    @Test("A directory that does not exist is empty, not an error")
    func missingDirectoryIsEmpty() {
        // The output directory is created when the first recording is written,
        // so a fresh install genuinely has none. "Where do I look" is still a
        // useful answer, and it is in `directory`.
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "no-such-\(UUID().uuidString)")
        let list = RecordingInventory.list(in: missing)
        #expect(list.total == 0)
        #expect(list.directory == missing.path)
    }

    @Test("A recording stamped in the future has an age of zero, not a negative one")
    func futureTimestampsClamp() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        try recording(in: directory, named: "ahead", createdAt: now.addingTimeInterval(600))
        #expect(RecordingInventory.list(in: directory, now: now).recordings.first?
            .ageSeconds == 0)
    }

    @Test("The list round-trips over the wire")
    func listEncodesAndDecodes() throws {
        let list = RecordingList(
            directory: "/tmp/Snitt", total: 1,
            recordings: [RecordingSummary(
                path: "/tmp/Snitt/x.snitt", byteSize: 10, ageSeconds: 5,
                createdAt: Date(timeIntervalSince1970: 1), initiator: "agent",
                outcome: "capped", durationSeconds: 12)],
            totalByteSize: 10)
        let back = try JSONDecoder().decode(
            RecordingList.self, from: JSONEncoder().encode(list))
        #expect(back == list)
    }
}
