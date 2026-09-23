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

/// What `snitt inspect` says about a recording that has ALREADY been edited.
///
/// The report described the bundle as it came off the camera: cuts and crops
/// were invisible, and `durationSeconds` was the untrimmed footage. An agent
/// returning to a bundle it had already cut was told the pre-edit state as
/// though it were current, so it could not tell the line it meant to remove had
/// already gone. In a real session that cost a whole re-take.
@Suite("Inspect reports the edit")
struct InspectReportsTheEditTests {

    private func editedBundle(cuts: [Cut], crop: CropRect?,
                              footage: Double = 60) throws -> SnittBundle {
        let bundle = try makeBundle()
        try RecordingMetadata(createdAt: Date(timeIntervalSince1970: 1000),
                              initiator: .agent,
                              durationSeconds: footage).write(to: bundle)
        var edl = EditDecisionList.fullRange()
        edl.cuts = cuts
        edl.crop = crop
        try edl.write(to: bundle)
        return bundle
    }

    @Test("Cuts already applied are listed, with what the edit now runs for")
    func cutsAreVisible() throws {
        let bundle = try editedBundle(
            cuts: [Cut(range: TimeRange(start: 5, end: 15), label: "waiting for build")],
            crop: nil)
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        let report = try InspectReport.report(for: bundle)
        #expect(report.cuts?.count == 1, "the cut in edit.json was not reported")
        #expect(report.cuts?.first?.startSeconds == 5)
        #expect(report.cuts?.first?.endSeconds == 15)
        #expect(report.cuts?.first?.label == "waiting for build")

        // The two durations are DIFFERENT numbers and both are needed: the
        // footage is what was captured, the output is what a viewer sits
        // through. Reporting only the first is what made an edited bundle look
        // untouched.
        #expect(report.durationSeconds == 60, "the footage length must not change")
        #expect(abs((report.outputDurationSeconds ?? 0) - 50) < 1e-9,
                "output reported as \(report.outputDurationSeconds as Any), expected 50")
    }

    @Test("A crop already applied is reported")
    func cropIsVisible() throws {
        let box = CropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let bundle = try editedBundle(cuts: [], crop: box)
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        #expect(try InspectReport.report(for: bundle).crop == box)
    }

    @Test("An untouched recording says so, rather than saying nothing")
    func untouchedIsEmptyNotAbsent() throws {
        // THE CONTROL. "No cuts" and "this report cannot say" are different
        // claims, which is why `cuts` is an array and not an Optional. And with
        // nothing cut the two durations must AGREE — a change that reported
        // some other number for output would pass the test above.
        let bundle = try editedBundle(cuts: [], crop: nil)
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        let report = try InspectReport.report(for: bundle)
        #expect(report.cuts == [])
        #expect(report.crop == nil)
        #expect(report.outputDurationSeconds == report.durationSeconds,
                "uncut, the footage and the edit are the same length")
    }

    @Test("A bundle with no edit.json reports no cuts rather than failing")
    func aPartialBundleStillAnswers() throws {
        // A recording interrupted before its sidecars were written has no
        // edit.json at all. "Nothing has been cut" is truthful for it, and the
        // report is exactly what an agent needs to decide what to do with the
        // debris — refusing would leave it with nothing.
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        try RecordingMetadata(createdAt: Date(timeIntervalSince1970: 1000),
                              initiator: .agent, durationSeconds: 12).write(to: bundle)

        let report = try InspectReport.report(for: bundle)
        #expect(report.cuts == [])
        #expect(report.outputDurationSeconds == 12)
    }

    @Test("An edit.json that exists and will not decode is refused, not read as untouched")
    func anUnreadableEDLIsRefused() throws {
        // §8. Reporting a corrupt or newer-schema edit.json as "no cuts" tells
        // an agent its bundle is untouched when a newer Snitt has already
        // edited it — and an agent told "no cuts" goes and cuts again, which is
        // worse here than the same mistake on markers.
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }
        try RecordingMetadata(createdAt: Date(timeIntervalSince1970: 1000),
                              initiator: .agent, durationSeconds: 12).write(to: bundle)
        try Data(#"{"schemaVersion":99999,"cuts":"not an array"}"#.utf8)
            .write(to: bundle.editURL)

        #expect(throws: (any Error).self) { _ = try InspectReport.report(for: bundle) }
    }
}

/// An older app's inspect payload, decoded by a newer client.
///
/// **This trap fired twice in one change.** A non-Optional property makes
/// synthesized `Codable` REQUIRE its key, so `cuts: [Cut]` — chosen because
/// "no cuts" and "cannot say" are genuinely different claims — decoded every
/// older Snitt's response as `keyNotFound` and broke `inspect` outright. The
/// same mistake in the same session had already broken `screenshotTaken` via a
/// defaulted `Bool`. Two instances is a class, so the rule is now stated where
/// the fields are: anything added to a shipped response is Optional, whatever
/// its natural type.
@Suite("Inspect wire compatibility")
struct InspectReportWireCompatibilityTests {

    @Test("A report written before the edit fields existed still decodes")
    func olderPayloadDecodes() throws {
        let old = #"""
        {"bundlePath":"/tmp/x.snitt","createdAt":0,"initiator":"agent",
         "durationSeconds":42,"markers":[],"markerCount":0,
         "inputEventCount":0,"reportedEventCount":0}
        """#
        let report = try JSONDecoder().decode(InspectReport.self, from: Data(old.utf8))
        #expect(report.durationSeconds == 42)
        // nil, NOT []: an app that does not carry the key has no opinion about
        // cuts, and a reader must be able to tell that from "nothing is cut".
        #expect(report.cuts == nil, "an older app must read as 'cannot say', not 'untouched'")
        #expect(report.outputDurationSeconds == nil)
        #expect(report.crop == nil)
    }

    @Test("A round trip keeps the edit, including the empty case")
    func roundTripsBothEmpties() throws {
        var report = try InspectReport.report(for: {
            let bundle = try InspectReportWireCompatibilityTests.emptyBundle()
            try RecordingMetadata(createdAt: Date(timeIntervalSince1970: 0),
                                  initiator: .agent, durationSeconds: 9).write(to: bundle)
            try EditDecisionList.fullRange().write(to: bundle)
            return bundle
        }())
        report.cuts = []
        let back = try JSONDecoder().decode(
            InspectReport.self, from: JSONEncoder().encode(report))
        #expect(back.cuts == [], "an explicit 'nothing is cut' must survive the wire as []")
    }

    private static func emptyBundle() throws -> SnittBundle {
        try SnittBundle(creatingAt: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension))
    }
}
