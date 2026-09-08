import Testing
import Foundation

// D47's conformance guard: a spec promise maps to a test, a task, or an explicit
// "not yet" — checked mechanically, so a settled decision cannot silently go
// unimplemented and a superseded one cannot silently keep asserting itself.
//
// D47 was decided after THREE instances of the class and then never built. The
// 2026-09-07 refinement pass found ELEVEN more, all one shape: a decision was
// superseded and the superseded text stayed put. Six stale citations of a gate
// D65 retired; §9 still forbidding the mechanism D51 and D64 adopted; M8 cut in
// the log but listed live in §13; D57 asserting a cost D59 refuted; and M4b,
// M5b and M5f built but absent from §13 entirely.
//
// The decision log is this project's warm-start cache — a later pass reads it
// and inherits whatever it says. That is why unacknowledged supersession is a
// correctness bug and not untidiness: it feeds a refuted premise forward as a
// fact.
//
// These checks are deliberately narrow. They verify that cross-references
// RESOLVE and that supersession is ACKNOWLEDGED — both mechanical. Whether a
// decision is wise is not checkable and is not attempted.
@Suite
struct SpecConformanceTests {
    private static let path = "docs/superpowers/specs/2026-09-02-snitt-design.md"
    private let spec: String

    init() throws {
        spec = try String(contentsOf: URL(fileURLWithPath: Self.path), encoding: .utf8)
    }

    private func matches(_ pattern: String, _ text: String? = nil) -> [[String]] {
        let subject = text ?? spec
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        return re.matches(in: subject, range: NSRange(subject.startIndex..., in: subject)).map { m in
            (0..<m.numberOfRanges).map { i in
                Range(m.range(at: i), in: subject).map { String(subject[$0]) } ?? ""
            }
        }
    }

    @Test("Every § cross-reference resolves to a real section")
    func sectionReferencesResolve() {
        var headings = Set<String>()
        for m in matches(#"^#+ (\d+(?:\.\d+)?)"#) {
            headings.insert(m[1])
            headings.insert(m[1].components(separatedBy: ".")[0])
        }
        #expect(headings.count > 20, "heading scan found almost nothing — the pattern has drifted")
        let referenced = Set(matches(#"§(\d+(?:\.\d+)?)"#).map { $0[1] })
        #expect(referenced.count > 20, "reference scan found almost nothing")
        let dangling = referenced.subtracting(headings).sorted()
        #expect(dangling.isEmpty, "§ references to sections that do not exist: \(dangling)")
    }

    @Test("Every D-number cross-reference resolves to a real decision row")
    func decisionReferencesResolve() {
        let rows = Set(matches(#"^\| (D\d+) \|"#).map { $0[1] })
        #expect(rows.count > 50, "decision-row scan found almost nothing")
        let referenced = Set(matches(#"\b(D\d+)\b"#).map { $0[1] })
        let dangling = referenced.subtracting(rows).sorted()
        #expect(dangling.isEmpty, "references to decisions that do not exist: \(dangling)")
    }

    @Test("A decision that supersedes another says so on BOTH rows")
    func supersessionIsAcknowledgedOnTheSupersededRow() {
        // Active voice only. "D30 ... SUPERSEDED by D33" is D30 correctly
        // carrying its own marker; reading that as "D30 supersedes D33" was a
        // false positive in the first draft of this check, and it flagged five
        // healthy rows. Only "supersedes/refutes/invalidates D<N>" obliges the
        // OTHER row to carry a marker.
        var unacknowledged: [String] = []
        for row in matches(#"^\| (D\d+) \|(.*)$"#) {
            let (source, body) = (row[1], row[2])
            for hit in matches(#"(?i)(?:supersedes|superseding|refutes|invalidates)\s+(D\d+)"#, body) {
                let target = hit[1]
                guard target != source,
                      let targetRow = matches(#"^\| \#(target) \|(.*)$"#).first else { continue }
                let acknowledged = !matches(#"(?i)REFUTED|SUPERSEDED|Amended|reversed"#, targetRow[1]).isEmpty
                if !acknowledged {
                    unacknowledged.append("\(source) supersedes/refutes \(target), but \(target) carries no marker")
                }
            }
        }
        #expect(unacknowledged.isEmpty, "a later decision overturned these and their own rows still assert the old claim:\n\(unacknowledged.joined(separator: "\n"))")
    }

    @Test("Every milestone the spec names appears in §13")
    func milestonesAppearInTheRoadmap() throws {
        // M4b, M5b and M5f were each decided, planned, built and shipped while
        // §13's list did not mention them. Work with no roadmap entry is the
        // mirror of D47's original case (a promise with no work), and it hid
        // three completed milestones from anyone reading the spec to find out
        // what exists.
        let roadmapStart = try #require(spec.range(of: "## 13. Milestones and priority"))
        let roadmapEnd = try #require(spec.range(of: "### Why signing moved into M2"))
        let roadmap = String(spec[roadmapStart.lowerBound..<roadmapEnd.lowerBound])

        let inRoadmap = Set(matches(#"\b(M\d+[a-f]?)\b"#, roadmap).map { $0[1] })
        let named = Set(matches(#"\b(M\d+[a-f]?)\b"#).map { $0[1] })
        #expect(inRoadmap.count > 5, "roadmap milestone scan found almost nothing")

        // "M2" is satisfied by M2a/M2b — a bare stem covered by a longer entry
        // is present, not missing.
        let missing = named.subtracting(inRoadmap)
            .filter { stem in !inRoadmap.contains { $0 != stem && $0.hasPrefix(stem) } }
            .sorted()
        #expect(missing.isEmpty, "milestones named in the spec but absent from §13: \(missing)")
    }
}
