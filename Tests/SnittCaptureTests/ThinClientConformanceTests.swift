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
