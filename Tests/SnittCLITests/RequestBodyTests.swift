import Testing
import Foundation
@testable import snitt_cli
import SnittAutomation

/// Tests for `requestBody(for:currentDirectory:)`, the mapping between a
/// parsed CLI command and the wire request `main.swift` sends.
///
/// `CommandLineParser` only handles raw strings — path RESOLUTION happens
/// here, against the caller's working directory (M3c finding #3;
/// `PathResolver`'s doc comment). A test that only checks
/// `CommandLineParser.parse` succeeded cannot see whether that resolution
/// step actually ran; these assert on the REQUEST BODY it produces instead.
@Test("A relative diagnostics --out is resolved before it is sent")
func relativeOutIsResolved() {
    guard case .success(.diagnosticsExport(let path)) =
        CommandLineParser.parse(["diagnostics", "export", "--out", "d.json"])
    else { Issue.record("parse failed"); return }

    let body = requestBody(for: .diagnosticsExport(outputPath: path),
                           currentDirectory: "/tmp/snitt-cwd-probe")

    guard case .diagnostics(let resolved) = body else {
        Issue.record("expected .diagnostics, got \(body)"); return
    }
    // The discriminating assertion. An implementation that forwards the raw
    // string verbatim — `body = .diagnostics(outputPath: path)`, the exact
    // finding #3 defect for `.trim`/`.export` before `PathResolver` existed —
    // passes a success-only assertion but sends a path the APP cannot
    // resolve, because `Snitt.app`'s own cwd is not the caller's.
    #expect(resolved == "/tmp/snitt-cwd-probe/d.json")
}

@Test("An absolute diagnostics --out is left alone")
func absoluteOutIsUnchanged() {
    let body = requestBody(for: .diagnosticsExport(outputPath: "/tmp/abs/d.json"),
                           currentDirectory: "/somewhere/else")
    guard case .diagnostics(let resolved) = body else {
        Issue.record("expected .diagnostics, got \(body)"); return
    }
    #expect(resolved == "/tmp/abs/d.json")
}

@Test("A diagnostics request is not sent through PathResolver twice")
func diagnosticsPathIsResolvedExactlyOnce() {
    // A plausible wrong implementation resolves in both `main.swift` AND
    // `CommandLineParser`, or resolves against the wrong base twice,
    // producing a path with a doubled or malformed prefix. `~` expansion is
    // the sharpest way to see a double-resolution: expanding it twice
    // against two different bases would not merely be redundant, it would
    // produce a visibly wrong path.
    let body = requestBody(for: .diagnosticsExport(outputPath: "~/d.json"),
                           currentDirectory: "/ignored")
    guard case .diagnostics(let resolved) = body else {
        Issue.record("expected .diagnostics, got \(body)"); return
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    #expect(resolved == home + "/d.json")
}
