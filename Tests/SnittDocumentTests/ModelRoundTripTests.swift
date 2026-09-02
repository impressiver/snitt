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

@Test("EventLog round-trips and preserves ordering")
func eventLogRoundTrips() throws {
    let bundle = try makeBundle()
    defer { try? FileManager.default.removeItem(at: bundle.url) }

    let written = EventLog(events: [
        LoggedEvent(timeSeconds: 0.5, kind: .click, label: nil),
        LoggedEvent(timeSeconds: 1.5, kind: .marker, label: "the fix"),
        LoggedEvent(timeSeconds: 2.5, kind: .keystroke, label: nil),
    ])
    try written.write(to: bundle)
    let read = try EventLog.read(from: bundle)

    #expect(read.events.count == 3)
    #expect(read.events[1].kind == .marker)
    #expect(read.events[1].label == "the fix")
    #expect(read.events.map(\.timeSeconds) == [0.5, 1.5, 2.5])
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
