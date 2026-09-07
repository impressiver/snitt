import Testing
import Foundation
@testable import SnittDocument

// One-shot: writes the CURRENT on-disk shape of edit.json to Tests/Fixtures so
// M5f Task 2's migration test has a real artifact rather than a remembered
// literal. Run deliberately with SNITT_CAPTURE_FIXTURE=1; skipped otherwise.
@Test("capture the shipping edit.json shape",
      .enabled(if: ProcessInfo.processInfo.environment["SNITT_CAPTURE_FIXTURE"] == "1"))
func captureShippingEDLShape() throws {
    let edl = EditDecisionList(
        schemaVersion: 1,
        cuts: [TimeRange(start: 1.5, end: 3.25), TimeRange(start: 10.0, end: 12.0)],
        trackStates: [TrackState(track: "mic", muted: true, gain: 0.5)])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(edl)
    let out = URL(fileURLWithPath: "Tests/Fixtures/edit-v0.1.0.json")
    try FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try data.write(to: out)
    print("wrote \(out.path): \(String(data: data, encoding: .utf8) ?? "")")
}
