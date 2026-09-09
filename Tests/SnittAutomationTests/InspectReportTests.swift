// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittAutomation
import SnittDocument

private func makeBundle() throws -> SnittBundle {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SnittBundle.fileExtension)
    return try SnittBundle(creatingAt: url)
}

@Test("A report carries what an agent needs to describe a recording it cannot watch")
func reportCarriesTheEssentials() throws {
    let bundle = try makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    try RecordingMetadata(
        createdAt: Date(timeIntervalSince1970: 1000),
        initiator: .agent,
        durationSeconds: 42.0,
        git: GitContext(branch: "feature/x", commit: "a1b2c3d"),
        health: CaptureHealth(meanFrameVariance: 500, micRMS: nil, systemAudioRMS: 0)
    ).write(to: bundle)

    try EventLog(events: [
        LoggedEvent(timeSeconds: 1, kind: .marker, label: "step one"),
        LoggedEvent(timeSeconds: 2, kind: .keystroke, label: nil),
        LoggedEvent(timeSeconds: 3, kind: .click, label: nil),
    ]).write(to: bundle)

    let report = try InspectReport.report(for: bundle)

    #expect(report.durationSeconds == 42.0)
    #expect(report.initiator == "agent")
    #expect(report.markerCount == 1)
    #expect(report.inputEventCount == 2)
    #expect(report.git?.branch == "feature/x")
    #expect(report.health?.meanFrameVariance == 500)
}

@Test("Marker labels are reported so an agent can name what it recorded")
func markerLabelsAreReported() throws {
    // §8: inspect exists so an agent can write something factually true —
    // "42s demo, chapters: repro / fix / verify" — rather than narrating a
    // video it has never seen.
    let bundle = try makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    try RecordingMetadata(createdAt: Date(), initiator: .agent).write(to: bundle)
    try EventLog(events: [
        LoggedEvent(timeSeconds: 1, kind: .marker, label: "repro"),
        LoggedEvent(timeSeconds: 9, kind: .marker, label: "fix"),
    ]).write(to: bundle)

    let report = try InspectReport.report(for: bundle)
    #expect(report.markers.map(\.label) == ["repro", "fix"])
    #expect(report.markers.map(\.timeSeconds) == [1, 9])
}

@Test("Input events contribute counts but never content")
func inputEventsAreCountedNotListed() throws {
    // The ruling: the log records that input happened, never what. A report
    // that listed input events individually would be the same disclosure by
    // another route.
    let bundle = try makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)
    try EventLog(events: (0..<5).map {
        LoggedEvent(timeSeconds: Double($0), kind: .keystroke, label: nil)
    }).write(to: bundle)

    let report = try InspectReport.report(for: bundle)
    #expect(report.inputEventCount == 5)
    #expect(report.markers.isEmpty, "only markers are listed individually")
}

@Test("A bundle with no sidecars still reports rather than throwing")
func missingSidecarsStillReport() throws {
    // An interrupted recording leaves a partial bundle. An agent asking about
    // it deserves an answer, not an error it cannot act on.
    let bundle = try makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)

    let report = try InspectReport.report(for: bundle)
    #expect(report.markerCount == 0)
    #expect(report.inputEventCount == 0)
}

/// D60/M5f Task 7: `report(for:)` used to read events.json with `(try?
/// EventLog.read(from: bundle))?.events ?? []` — the exact collapsing
/// pattern already fixed at `MovieExporter`'s and `AutomationHost`'s
/// `events.json` call sites (and at `DocumentOpener`'s `edit.json` one),
/// left standing here. A `schemaVersion` newer than this build understands
/// is a real events.json that EXISTS and fails to decode — collapsing that
/// into "zero events" would tell an agent a recording has no markers when
/// really its own build is too old to read them. Verified to fail against
/// that exact collapsing form: `(try? EventLog.read(from: bundle))?.events
/// ?? []` swallows this and `missingSidecarsStillReport`'s empty-report
/// shape (`markerCount == 0`) would pass instead of this throw.
@Test("A future-schemaVersion events.json throws rather than silently reporting no markers")
func futureSchemaVersionEventsThrowsRatherThanEmptyReport() throws {
    let bundle = try makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }
    try RecordingMetadata(createdAt: Date(), initiator: .human).write(to: bundle)
    try Data(#"{"schemaVersion":99,"events":[]}"#.utf8).write(to: bundle.eventsURL)

    #expect(throws: EventLogError.unsupportedSchemaVersion(found: 99, maxSupported: EventLog.currentSchemaVersion)) {
        _ = try InspectReport.report(for: bundle)
    }
}
