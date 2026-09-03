import Testing
import Foundation

/// Locates the repository root from this file's own path.
private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)          // Tests/SnittCaptureTests/ThisFile.swift
        .deletingLastPathComponent()          // Tests/SnittCaptureTests
        .deletingLastPathComponent()          // Tests
        .deletingLastPathComponent()          // repo root
}

/// Removes `//` line comments and `/* */` block comments.
///
/// The guard matches source text, so without this a file could satisfy it with
/// a COMMENT mentioning the call it never makes — and every historical instance
/// of this defect lived in a file with a paragraph of prose about permissions.
/// A guard a comment can defeat is not a guard.
///
/// This deliberately does NOT handle string literals containing `//` (e.g. a URL
/// in a string literal would have the rest of that line stripped). That is a
/// conscious trade-off: it can only produce a false POSITIVE (the guard
/// complains when it should not), which fails loudly and a human adjusts. The
/// direction that must never happen is a false NEGATIVE — a comment hiding a
/// missing call — and this closes that.
private func strippingComments(_ source: String) -> String {
    var out = ""
    var index = source.startIndex
    var inLine = false, inBlock = false

    while index < source.endIndex {
        let rest = source[index...]
        if inLine {
            if source[index] == "\n" { inLine = false; out.append("\n") }
            index = source.index(after: index)
        } else if inBlock {
            if rest.hasPrefix("*/") {
                inBlock = false
                index = source.index(index, offsetBy: 2)
            } else {
                index = source.index(after: index)
            }
        } else if rest.hasPrefix("//") {
            inLine = true
            index = source.index(index, offsetBy: 2)
        } else if rest.hasPrefix("/*") {
            inBlock = true
            index = source.index(index, offsetBy: 2)
        } else {
            out.append(source[index])
            index = source.index(after: index)
        }
    }
    return out
}

private func swiftSources() -> [URL] {
    let root = repositoryRoot()
    var found: [URL] = []
    for directory in ["Sources", "Spikes"] {
        let base = root.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: nil) else { continue }
        for case let url as URL in walker where url.pathExtension == "swift" {
            found.append(url)
        }
    }
    return found
}

@Test("No file preflights a TCC grant without also requesting it")
func noPreflightWithoutRequest() throws {
    // The recurrence, stated as a rule. Preflight READS the current grant;
    // Request RAISES the dialog and registers the app in System Settings. A file
    // that only preflights silently measures nothing — three times now.
    var offenders: [String] = []
    for url in swiftSources() {
        let source = strippingComments(try String(contentsOf: url, encoding: .utf8))
        for service in ["ScreenCapture", "ListenEvent"] {
            if source.contains("CGPreflight\(service)Access"),
               !source.contains("CGRequest\(service)Access") {
                offenders.append("\(url.lastPathComponent): preflights \(service) but never requests it")
            }
        }
    }
    #expect(offenders.isEmpty, "\(offenders)")
}

@Test("Every production enumeration site ensures access first, or is allowlisted")
func enumerationSitesEnsureAccess() throws {
    // `SCShareableContent` returns nothing useful without the grant, and asking
    // for it is what makes the app appear in System Settings. Any NEW production
    // file that enumerates must either route through ScreenRecordingAccess or
    // add itself here with a written reason — the point being that the choice
    // becomes deliberate instead of forgotten.
    //
    // Scans Sources/ only. Spikes/ is throwaway, historical, and several of its
    // probes predate this rule; the preflight test above still covers them,
    // which is the half that actually bit us there.
    let allowed: [String: String] = [
        "CaptureTarget.swift":
            "A pure enumeration helper. Its callers ensure access; it deliberately "
            + "does not prompt, so listing composes without side effects.",
        "CachedTargetResolver.swift":
            "Resolves a stored reference against live windows. Reached only from "
            + "RecordingCoordinator, which ensures access before resolving.",
        "ScreenRecordingAccess.swift":
            "The helper itself.",
    ]

    let root = repositoryRoot().appendingPathComponent("Sources")
    var offenders: [String] = []
    for url in swiftSources() where url.path.hasPrefix(root.path) {
        let name = url.lastPathComponent
        let source = strippingComments(try String(contentsOf: url, encoding: .utf8))
        guard source.contains("SCShareableContent.") else { continue }
        if allowed[name] != nil { continue }
        if source.contains("ScreenRecordingAccess.ensureGranted")
            || source.contains("CGRequestScreenCaptureAccess") { continue }
        offenders.append("\(name): enumerates SCShareableContent without ensuring access")
    }
    #expect(offenders.isEmpty, "\(offenders)")
}
