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
