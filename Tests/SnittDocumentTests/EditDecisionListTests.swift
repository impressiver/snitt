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

// MARK: - M5f whole-branch review, F4: what a WRITE declares

/// A stand-in for a build that understands `edit.json` schemaVersion 1 and
/// nothing newer — D60's own scenario, since updates are hand-delivered
/// (D54) and an old and a new Snitt can sit on one machine. It applies
/// exactly the rule `EditDecisionList.init(from:)` applies, with its own,
/// lower ceiling.
///
/// The point of decoding only the header: a v1 build's `Cut` is a bare
/// `TimeRange`, and it would decode an `id`-bearing cut without complaint.
/// That is precisely why the DECLARED version has to be right — the gate is
/// the only thing standing between an old build and a file it cannot
/// faithfully represent.
private enum SchemaVersionOneBuild {
    static let maxSupported = 1

    static func read(_ data: Data) throws {
        struct Header: Decodable { let schemaVersion: Int }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.schemaVersion <= maxSupported else {
            throw EditDecisionListError.unsupportedSchemaVersion(
                found: header.schemaVersion, maxSupported: maxSupported)
        }
    }
}

/// F4 (Major): `edit.json` was written back declaring whatever version it
/// was READ as, so a v0.1.0 bundle edited by this build kept saying
/// `schemaVersion: 1` while carrying schema-2, `id`-bearing cuts — and
/// D60's gate never fired for any bundle that actually exists.
///
/// It was harmless only because `Cut`'s encoding happens to be flat and
/// additive (`{id, start, end}`), so a v0.1.0 `TimeRange` decoder ignores
/// the extra key. That is an accident of the current shape, not a design;
/// the next non-additive change to `edit.json` turns it into exactly the
/// silent, unrecoverable loss `EditDecisionListError`'s own message
/// promises to prevent.
struct EditDecisionListWriteVersionTests {
    private func makeBundle() throws -> SnittBundle {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        return try SnittBundle(creatingAt: url)
    }

    /// The real v0.1.0 fixture, edited and saved — the path every existing
    /// bundle takes. A mutant that writes `self.schemaVersion` back (the
    /// pre-fix behaviour) declares 1 here.
    @Test("A legacy edit.json saved by this build declares THIS build's schemaVersion")
    func savingALegacyEDLStampsTheCurrentVersion() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        let legacy = try EditDecisionList.decode(
            from: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/edit-v0.1.0.json")))
        #expect(legacy.schemaVersion == 1, "the fixture is the pre-M5f shape, or this test is aimed at nothing")

        var edited = legacy
        edited.cuts.append(Cut(range: TimeRange(start: 6, end: 7)))
        try edited.write(to: bundle)

        let written = try Data(contentsOf: bundle.editURL)
        struct Header: Decodable { let schemaVersion: Int }
        let header = try JSONDecoder().decode(Header.self, from: written)
        #expect(header.schemaVersion == EditDecisionList.currentSchemaVersion)

        // Not a version number in isolation: the file really does carry the
        // schema-2 content the number is claiming.
        #expect(String(data: written, encoding: .utf8)?.contains("\"id\"") == true)
    }

    /// The half that makes the number load-bearing rather than decorative:
    /// a build with a lower ceiling must REFUSE a file this build wrote.
    /// Before the fix it accepted one, `id`s and all, and its next save
    /// would have written back whatever it could represent.
    @Test("A build that understands only schemaVersion 1 refuses a file this build wrote")
    func anOlderBuildRefusesWhatThisBuildWrites() throws {
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.url) }

        let legacy = try EditDecisionList.decode(
            from: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/edit-v0.1.0.json")))
        try legacy.write(to: bundle)

        let written = try Data(contentsOf: bundle.editURL)
        #expect(throws: EditDecisionListError.unsupportedSchemaVersion(
            found: EditDecisionList.currentSchemaVersion,
            maxSupported: SchemaVersionOneBuild.maxSupported)) {
            try SchemaVersionOneBuild.read(written)
        }
    }

    /// `snitt trim`'s write path reads and writes the same value, so it had
    /// the identical defect. `trimmed(keeping:duration:)` carries
    /// `schemaVersion` forward explicitly, which is fine in memory — the
    /// stamp belongs on the WRITE — but a fix applied only at
    /// `EditDecisionList.write(to:)` and not at the encoder would miss any
    /// other caller that encodes an EDL directly.
    @Test("A trimmed legacy EDL also encodes THIS build's schemaVersion")
    func trimmingALegacyEDLStampsTheCurrentVersion() throws {
        let legacy = try EditDecisionList.decode(
            from: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/edit-v0.1.0.json")))
        let trimmed = legacy.trimmed(keeping: TimeRange(start: 1, end: 9), duration: 20)

        let encoded = try JSONEncoder().encode(trimmed)
        struct Header: Decodable { let schemaVersion: Int }
        let header = try JSONDecoder().decode(Header.self, from: encoded)
        #expect(header.schemaVersion == EditDecisionList.currentSchemaVersion)
    }
}
