// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

private func makeBundle() throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    return try SnittBundle(creatingAt: url)
}

@Test("RecordingMetadata round-trips through the bundle")
func metadataRoundTrips() throws {
    let bundle = try makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let written = RecordingMetadata(
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        initiator: .agent,
        durationSeconds: 42.5,
        git: GitContext(branch: "feature/x", commit: "a1b2c3d"),
        health: nil
    )
    try written.write(to: bundle)
    let read = try RecordingMetadata.read(from: bundle)

    #expect(read.initiator == .agent)
    #expect(read.durationSeconds == 42.5)
    #expect(read.git?.branch == "feature/x")
    #expect(read.schemaVersion == 1)
}

@Test("EventLog round-trips and preserves write order, not time order")
func eventLogRoundTrips() throws {
    let bundle = try makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    // Deliberately NOT in ascending time order: an implementation that
    // sorted by timeSeconds would reorder these, and must not.
    let written = EventLog(events: [
        LoggedEvent(timeSeconds: 2.5, kind: .marker, label: "the fix"),
        LoggedEvent(timeSeconds: 0.5, kind: .click, label: nil),
        LoggedEvent(timeSeconds: 1.5, kind: .keystroke, label: nil),
    ])
    try written.write(to: bundle)
    let read = try EventLog.read(from: bundle)

    #expect(read.events.count == 3)
    #expect(read.events.map(\.timeSeconds) == [2.5, 0.5, 1.5],
            "write order must survive the round trip unsorted")
    #expect(read.events[0].kind == .marker)
    #expect(read.events[0].label == "the fix")
    #expect(read.events[1].label == nil)
}

/// M5f Task 6 (D50/D56): `LoggedEvent` gained `id` and `transcript`.
@Test("A marker's id and transcript round-trip through events.json")
func eventLogRoundTripsIdAndTranscript() throws {
    let bundle = try makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let marker = LoggedEvent(timeSeconds: 4.0, kind: .marker,
                             label: "the fix", transcript: "here is where we fixed it")
    try EventLog(events: [marker]).write(to: bundle)
    let read = try EventLog.read(from: bundle)

    let readBack = try #require(read.events.first)
    // A mutant that never encodes `transcript` (only decodes it) would pass
    // an in-memory-only check; round-tripping through the actual file on
    // disk is what `write`/`read` catch that an in-memory comparison would
    // not.
    #expect(readBack.transcript == "here is where we fixed it")
    #expect(readBack.id == marker.id)
}

/// D60's own gap, named rather than closed by this task (see `EventLog`'s
/// doc comment): a pre-M5f-Task-6 `events.json` has no `id`/`transcript` key
/// at all, and must still open. Hand-written rather than a captured fixture
/// (unlike `edit-v0.1.0.json`): the field names this depends on
/// (`schemaVersion`, `events`, `timeSeconds`, `kind`, `label`) are the
/// CURRENT, unchanged shape — nothing here was ever renamed the way
/// `trackStates` was, so there is no "remembered literal" risk to guard
/// against with a captured file.
@Test("A legacy events.json with no id or transcript key still opens, minting distinct ids")
func eventLogReadsLegacyEventsWithoutIdOrTranscript() throws {
    let json = """
    {"schemaVersion":1,"events":[
        {"timeSeconds":1.0,"kind":"marker","label":"a"},
        {"timeSeconds":2.0,"kind":"marker","label":"b"}
    ]}
    """
    let log = try EventLog.decode(from: Data(json.utf8))

    #expect(log.events.count == 2)
    #expect(log.events.map(\.label) == ["a", "b"])
    #expect(log.events.allSatisfy { $0.transcript == nil })
    // Every legacy event got a REAL, DISTINCT id even though the file has
    // none — a mutant that mints the SAME id for every legacy event (e.g. a
    // fixed sentinel UUID instead of `UUID()`) still gives every event "an
    // id" but makes them indistinguishable, exactly the bug identity exists
    // to prevent (mirrors `EditDecisionListTests.readsLegacyCuts`).
    #expect(Set(log.events.map(\.id)).count == log.events.count)
}

/// M5f Task 7 (D60): `EventLog.currentSchemaVersion` was bumped 1 -> 2 by
/// Task 6 without this guard — the same D60 gate `EditDecisionListTests`
/// already pins for `edit.json`, applied here to `events.json`. Mirrors
/// `EditDecisionListTests.refusesFutureSchema` exactly, on the sibling type.
@Test("A newer events.json schemaVersion is refused, loudly")
func eventLogRefusesFutureSchema() throws {
    let future = #"{"schemaVersion":99,"events":[]}"#
    #expect(throws: EventLogError.unsupportedSchemaVersion(
        found: 99, maxSupported: EventLog.currentSchemaVersion)) {
        _ = try EventLog.decode(from: Data(future.utf8))
    }
}

/// The companion case to `eventLogRefusesFutureSchema`: a mutant that
/// rejects every version but 1 (rather than "greater than
/// currentSchemaVersion") would fail here, since a fresh `EventLog` written
/// by THIS build encodes schemaVersion 2.
@Test("The current events.json schemaVersion still opens — the gate is forward-only")
func eventLogCurrentSchemaVersionIsAccepted() throws {
    let json = #"{"schemaVersion":\#(EventLog.currentSchemaVersion),"events":[]}"#
    let log = try EventLog.decode(from: Data(json.utf8))
    #expect(log.schemaVersion == EventLog.currentSchemaVersion)
}

@Test("A new EDL defaults to no cuts and unmuted tracks")
func editListDefaults() throws {
    let bundle = try makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let written = EditDecisionList.fullRange()
    try written.write(to: bundle)
    let read = try EditDecisionList.read(from: bundle)

    #expect(read.cuts.isEmpty)
    #expect(read.trackStates.count == 3)
    #expect(read.trackStates.allSatisfy { !$0.muted })
    #expect(read.trackStates.allSatisfy { $0.gain == 1.0 })
}

// MARK: - D108: how an agent's session ended, on the bundle

@Test("A meta.json written before `outcome` existed still decodes")
func metadataWithoutOutcomeDecodes() throws {
    // DISCRIMINATES AGAINST: a non-Optional `outcome`, which would fail
    // `keyNotFound` on every bundle already on disk. `RecordingMetadata`
    // carries a `schemaVersion` that is compared NOWHERE (see
    // `RecordingCoordinator.openEditorIfHuman`'s note), so the version gate
    // would not catch this either: the first symptom would be a recording
    // that stopped opening.
    let json = Data(#"""
        {"schemaVersion":1,"createdAt":"2026-09-01T10:00:00Z","initiator":"agent"}
        """#.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let meta = try decoder.decode(RecordingMetadata.self, from: json)
    #expect(meta.outcome == nil)
    #expect(meta.initiator == .agent)
}

@Test("An outcome survives a write and a read")
func metadataOutcomeRoundTrips() throws {
    let bundle = try SnittBundle(creatingAt: FileManager.default.temporaryDirectory
        .appending(path: "meta-outcome-\(UUID().uuidString).snitt"))
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    try RecordingMetadata(createdAt: Date(), initiator: .agent,
                          outcome: "capped").write(to: bundle)
    #expect(try RecordingMetadata.read(from: bundle).outcome == "capped")
}
