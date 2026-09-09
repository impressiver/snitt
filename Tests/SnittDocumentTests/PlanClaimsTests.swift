import Foundation
import Testing

// D91: a plan item that says "not yet built" must be falsifiable.
//
// §13 has described already-shipped work as pending FIVE times — crop, D73's
// speaker-bleed warning, M5e's agent primitives (with three of S5's four
// premises stale), D57's transcript word spans, and D86, which was written and
// then ranked inside a single session. `field-notes.md` concluded no cheap
// mechanical check could catch this "because 'is this built?' is not answerable
// from prose."
//
// That is true of prose and false of a symbol name. An item that declares
// `absent: GainEnvelope` is making a claim a grep falsifies in milliseconds, and
// every one of the five instances would have failed this check on the day it was
// written.
//
// Deliberately one-directional: this proves ABSENCE, never presence. It cannot
// tell anyone an item is finished — only that a "not yet built" claim has
// already stopped being true. That is the half that kept going wrong.
//
// Lives in SnittDocumentTests rather than beside `SpecConformanceTests` in
// SnittAppTests on purpose: SnittAppTests is one of the two targets CI cannot
// run (they hang on a headless runner), so a guard placed there would not run on
// a pull request. This check is pure text and costs milliseconds.
@Suite
struct PlanClaimsTests {
    private static let specPath = "docs/superpowers/specs/2026-09-02-snitt-design.md"
    private static let sourcesPath = "Sources"

    /// Every `absent: Name` marker in the spec, in declaration order.
    private static func declaredAbsent(in spec: String) -> [String] {
        let pattern = #"`absent: ([A-Za-z_][A-Za-z0-9_]*)`"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: spec, range: NSRange(spec.startIndex..., in: spec)).compactMap {
            Range($0.range(at: 1), in: spec).map { String(spec[$0]) }
        }
    }

    /// Whether `name` is DECLARED anywhere in the sources.
    ///
    /// Matches a declaration, not a mention: `struct Segment` counts and
    /// `// a Segment would…` does not. A bare substring search would fire on the
    /// spec's own vocabulary appearing in a comment, which would make the guard
    /// cry wolf until somebody deleted it.
    private static func isDeclared(_ name: String, under root: String) -> Bool {
        let pattern = "(struct|enum|class|protocol|actor|typealias|func|var|let)[ \t]+\(name)\\b"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let files = FileManager.default.enumerator(atPath: root)?
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") } ?? []
        for file in files {
            guard let text = try? String(contentsOfFile: "\(root)/\(file)", encoding: .utf8)
            else { continue }
            if re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                return true
            }
        }
        return false
    }

    @Test("The spec actually carries absence markers")
    func markersExist() throws {
        // Without this the suite passes vacuously the moment the marker syntax
        // drifts — a green test asserting nothing, which is worse than no test
        // because it reads as coverage. This project has found twenty-six tests
        // that asserted a property adjacent to the one that mattered.
        let spec = try String(contentsOfFile: Self.specPath, encoding: .utf8)
        let names = Self.declaredAbsent(in: spec)
        #expect(names.count >= 4, "found \(names.count) absence markers; the syntax has drifted")
    }

    @Test("Nothing the plan calls unbuilt is already built")
    func unbuiltClaimsAreStillTrue() throws {
        let spec = try String(contentsOfFile: Self.specPath, encoding: .utf8)
        let built = Self.declaredAbsent(in: spec)
            .filter { Self.isDeclared($0, under: Self.sourcesPath) }
        #expect(built.isEmpty, """
            §13 calls these unbuilt, but they are declared in Sources/: \(built).
            This is the failure mode D91 exists to catch — the plan describing \
            shipped work as pending. Update the item rather than deleting its marker.
            """)
    }

    @Test("The guard can tell the difference — a name that IS built is detected")
    func theGuardDetectsSomethingReal() {
        // The control. `unbuiltClaimsAreStillTrue` passes both when the guard
        // works and when `isDeclared` silently matches nothing — a broken path,
        // a wrong root, an enumerator returning empty. This pins the detector
        // against a symbol that certainly exists, so the green above means
        // "checked and clear" rather than "looked nowhere".
        #expect(Self.isDeclared("Timebase", under: Self.sourcesPath))
        #expect(Self.isDeclared("KeptRanges", under: Self.sourcesPath))
        #expect(!Self.isDeclared("NoSuchTypeExistsAnywhere", under: Self.sourcesPath))
    }
}
