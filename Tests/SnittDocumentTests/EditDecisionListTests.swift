import Testing
import Foundation
@testable import SnittDocument

/// M5f Task 2: cuts gained identity (`Cut { id, range }`), and decoding a
/// `schemaVersion` newer than this build understands is refused rather than
/// silently accepted (D60). See `EditDecisionListEditTests.swift` for the
/// pre-existing `trimmed(keeping:duration:)` behavior these two changes had
/// to keep working.
struct EditDecisionListTests {
    @Test("A real v0.1.0 edit.json still opens")
    func readsLegacyCuts() throws {
        // Tests/Fixtures/edit-v0.1.0.json was CAPTURED from the shipping
        // encoder (commit 3731ad4) before this task changed the format —
        // not hand-written. A remembered literal is exactly the risk a
        // captured fixture removes: an earlier draft of this test used one
        // with a `tracks` key; the real field is `trackStates`.
        let data = try Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/edit-v0.1.0.json"))
        let edl = try EditDecisionList.decode(from: data)

        #expect(edl.cuts.count == 2)
        #expect(edl.cuts[0].range == TimeRange(start: 1.5, end: 3.25))
        #expect(edl.cuts[1].range == TimeRange(start: 10, end: 12))
        #expect(edl.trackStates.count == 1)          // trackStates survived too

        // Every cut got a REAL, DISTINCT id even though the file has none —
        // otherwise the fold UI (Task 5) cannot address cuts from a bundle
        // recorded before this milestone. `Cut.id` is a non-optional UUID
        // (not the brief's draft `Optional`, which cannot compile against
        // `!= nil`), so the meaningful assertion is uniqueness: a mutant
        // that mints the SAME id for every legacy cut (e.g. a fixed
        // sentinel UUID instead of `UUID()`) still gives every cut "an id"
        // but makes them indistinguishable — exactly the bug identity
        // exists to prevent.
        #expect(Set(edl.cuts.map(\.id)).count == edl.cuts.count)
    }

    @Test("A newer schemaVersion is refused, loudly")
    func refusesFutureSchema() throws {
        // D60. Updates are hand-delivered, so old and new builds coexist and
        // edit.json is the only place cuts live. Codable would happily decode a
        // newer file into defaults and the next write would destroy what it could
        // not represent — silent, and unrecoverable.
        let future = #"{"schemaVersion":99,"cuts":[],"trackStates":[]}"#
        #expect(throws: EditDecisionListError.unsupportedSchemaVersion(
            found: 99, maxSupported: EditDecisionList.currentSchemaVersion)) {
            _ = try EditDecisionList.decode(from: Data(future.utf8))
        }
    }

    @Test("The current schemaVersion still opens — the gate is forward-only")
    func currentSchemaVersionIsAccepted() throws {
        // The companion case to `refusesFutureSchema`: a mutant that rejects
        // every version but 1 (rather than "greater than currentSchemaVersion")
        // would fail here, since a fresh document written by THIS build
        // encodes schemaVersion 2.
        let json = #"{"schemaVersion":\#(EditDecisionList.currentSchemaVersion),"cuts":[],"trackStates":[]}"#
        // An uncaught throw here fails this (`throws`) test on its own —
        // no need for `#expect(throws: Never.self)`.
        let edl = try EditDecisionList.decode(from: Data(json.utf8))
        #expect(edl.schemaVersion == EditDecisionList.currentSchemaVersion)
    }

    @Test("Two identical spans are distinguishable cuts")
    func identicalSpansAreDistinct() {
        let a = Cut(range: TimeRange(start: 1, end: 2))
        let b = Cut(range: TimeRange(start: 1, end: 2))
        // Value-equal ranges, different cuts. Without this, removing one removes
        // both, and the fold UI cannot tell which one was clicked.
        #expect(a.id != b.id)
    }
}
