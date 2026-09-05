import Testing
import Foundation

/// §4.9's thin-client invariant, stated as a rule instead of a comment.
///
/// No frontend may call ScreenCaptureKit. macOS attributes the Screen Recording
/// grant to the RESPONSIBLE process, which for a CLI is whatever launched it —
/// so a capturing `snitt` re-prompts for every new parent process, and the
/// permission the app already holds does nothing. Capture must stay in the
/// resident app; the CLI and the MCP server only speak the socket protocol.
///
/// This lived only in prose. `Package.swift` declared `SnittAutomation`
/// depending on `SnittCapture` and `SnittDocument` while no file under
/// `Sources/SnittAutomation/` imported either, so both `snitt-cli` and
/// `snitt-mcp` transitively linked ScreenCaptureKit. Those dependencies are
/// gone; this test is what keeps them gone.
///
/// It lives in `SnittCaptureTests` — despite being about the automation
/// targets — to reuse `strippingCommentsAndLiterals` from
/// `AccessConformanceTests.swift` rather than fork a second copy of a
/// hand-rolled Swift lexer. A comment mentioning an import must not satisfy or
/// trip this guard, which is exactly what that helper exists to guarantee.

/// Directories that must never reach the capture stack, and why.
private let thinTargets = [
    "Sources/snitt-cli",
    "Sources/snitt-mcp",
    "Sources/SnittAutomation",
]

/// The modules that pull in, or ARE, the capture stack.
private let forbiddenImports = ["ScreenCaptureKit", "AVFoundation", "SnittCapture"]

private func swiftFiles(under relativePath: String) -> [URL] {
    let base = repositoryRoot().appendingPathComponent(relativePath)
    guard let walker = FileManager.default.enumerator(
        at: base, includingPropertiesForKeys: nil) else { return [] }
    var found: [URL] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
        found.append(url)
    }
    return found
}

@Test("No frontend or protocol file imports the capture stack")
func thinClientsDoNotImportCapture() throws {
    var offenders: [String] = []
    var scanned = 0

    for directory in thinTargets {
        for url in swiftFiles(under: directory) {
            scanned += 1
            let source = strippingCommentsAndLiterals(
                try String(contentsOf: url, encoding: .utf8))
            for line in source.split(separator: "\n", omittingEmptySubsequences: true) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let module = trimmed.dropFirst("import ".count)
                    .trimmingCharacters(in: .whitespaces)
                if forbiddenImports.contains(module) {
                    offenders.append("\(directory)/\(url.lastPathComponent): imports \(module)")
                }
            }
        }
    }

    // Guards the guard: a typo in a path would make this pass vacuously by
    // scanning nothing at all.
    #expect(scanned > 0, "the thin-client directories should not be empty")
    #expect(offenders.isEmpty,
            "§4.9: capture belongs to the resident app, because macOS attributes the grant to the responsible process — \(offenders)")
}

/// The modules a thin target may never DEPEND on, whether or not it imports them.
///
/// Separate from `forbiddenImports` because the original defect was a declared
/// dependency that no file imported — SwiftPM links it regardless, so an
/// import scan cannot see it. `SnittDocument` is permitted: it imports only
/// Foundation and carries no capture stack.
private let forbiddenDependencies = ["SnittCapture"]

/// Extracts the text of one target's declaration from a `Package.swift`
/// manifest, so `thinTargetsDoNotDependOnCapture` can check its dependency
/// array without a real Swift parser.
///
/// Finds `name: "<target>"`, walks backward to the nearest preceding
/// `.target(`/`.executableTarget(`/`.testTarget(` opener, then walks forward
/// counting paren depth until it returns to zero — that closing paren ends
/// the declaration. This assumes the manifest's dependency arrays contain no
/// parentheses of their own, which holds today; if the manifest's formatting
/// ever defeats this, say so rather than growing this into an ad hoc parser.
///
/// The name search is scoped to start AFTER the top-level `targets: [` array
/// opens, matched as `"\n    targets: [\n"` rather than the bare substring
/// `"targets: ["`. Two collisions would otherwise be possible: every target
/// with a library product (`SnittAutomation` among them) also appears as
/// `.library(name: "<target>", targets: [...])` earlier, in `products:` — and
/// that same `.library(...)` call ALSO contains the bare substring
/// `"targets: ["` inline, ahead of the real array. Either collision finds the
/// wrong occurrence, and the product one has no enclosing `.target(`-family
/// opener at all, so the backward search below would silently come up empty
/// and the whole check would pass vacuously for exactly the target this test
/// most needs to watch.
func targetDeclaration(named target: String, in manifest: String) -> String? {
    guard let targetsSection = manifest.range(of: "\n    targets: [\n") else { return nil }
    let scope = targetsSection.upperBound..<manifest.endIndex

    let needle = "name: \"\(target)\""
    guard let nameRange = manifest.range(of: needle, range: scope) else { return nil }

    let openers = [".target(", ".executableTarget(", ".testTarget("]
    var openerStart: String.Index?
    for opener in openers {
        guard let range = manifest.range(
            of: opener, options: .backwards,
            range: scope.lowerBound..<nameRange.lowerBound
        ) else { continue }
        if openerStart == nil || range.lowerBound > openerStart! {
            openerStart = range.lowerBound
        }
    }
    guard let start = openerStart else { return nil }

    var depth = 0
    var index = start
    while index < manifest.endIndex {
        let character = manifest[index]
        if character == "(" {
            depth += 1
        } else if character == ")" {
            depth -= 1
            if depth == 0 {
                return String(manifest[start...index])
            }
        }
        index = manifest.index(after: index)
    }
    return nil // unbalanced parens — the manifest is malformed, not just naive
}

@Test("No thin target declares a dependency on the capture stack")
func thinTargetsDoNotDependOnCapture() throws {
    // The import scan above cannot catch this: SwiftPM links a declared
    // dependency whether or not any file imports it, which is exactly how
    // snitt-cli and snitt-mcp came to link ScreenCaptureKit in the first place.
    let manifest = try String(
        contentsOf: repositoryRoot().appendingPathComponent("Package.swift"),
        encoding: .utf8)

    var offenders: [String] = []
    for target in ["snitt-cli", "snitt-mcp", "SnittAutomation"] {
        guard let declaration = targetDeclaration(named: target, in: manifest) else {
            Issue.record("could not find the \(target) target in Package.swift")
            continue
        }
        for module in forbiddenDependencies where declaration.contains("\"\(module)\"") {
            offenders.append("\(target) declares a dependency on \(module)")
        }
    }
    #expect(offenders.isEmpty, "\(offenders)")
}

@Test("The scanner sees a real import but not one that is only mentioned")
func importScannerDistinguishesMentionsFromImports() {
    // Both directions matter. A comment naming an import must not FAIL the
    // guard, and a real import must not be excused by one.
    #expect(strippingCommentsAndLiterals("// import ScreenCaptureKit\nimport Foundation")
        .contains("import ScreenCaptureKit") == false,
            "a mention in a comment must not trip the guard")
    #expect(strippingCommentsAndLiterals("import ScreenCaptureKit")
        .contains("import ScreenCaptureKit"),
            "a real import must survive stripping, or the guard proves nothing")
}
