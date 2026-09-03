import Testing
import Foundation

/// Locates the repository root from this file's own path.
private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)          // Tests/SnittCaptureTests/ThisFile.swift
        .deletingLastPathComponent()          // Tests/SnittCaptureTests
        .deletingLastPathComponent()          // Tests
        .deletingLastPathComponent()          // repo root
}

/// Returns `source` with comments and string-literal CONTENTS removed, so that
/// a match against the result means a real call site and not a mention.
///
/// Both removals close false negatives found in review: an identifier named in
/// a doc comment, or quoted inside an error message, previously satisfied the
/// guard while the call was never made. Stripping errs toward removing too
/// much — that direction produces a false POSITIVE, which fails loudly and a
/// human adjusts. A false negative ships the defect silently, which is the
/// whole failure this guard exists to prevent.
///
/// Handles, in one pass, and without letting one construct nest inside
/// another it should not (a `//` inside a string is not a comment; a `"`
/// inside a comment does not open a literal):
/// - `//` line comments
/// - `/* ... */` block comments, with a nesting depth counter — Swift allows
///   `/* /* */ */`, and a scanner that closes on the first `*/` mishandles it
/// - `"..."` string literals, respecting `\"` escapes
/// - `"""..."""` multiline string literals
/// - raw strings: any `#"` is treated as opening a literal that runs to the
///   next `"#`. This under-counts delimiters for `##"..."##` and deeper, but
///   that only means it can stop stripping early inside an unusual raw
///   string — a false positive risk, not a false negative one — so it is the
///   safe direction and not worth the extra complexity here.
private func strippingCommentsAndLiterals(_ source: String) -> String {
    let chars = Array(source)
    let n = chars.count
    var out = ""
    out.reserveCapacity(n)
    var i = 0
    var blockDepth = 0

    func has(_ needle: String, at index: Int) -> Bool {
        let needleChars = Array(needle)
        guard index + needleChars.count <= n else { return false }
        for k in 0..<needleChars.count where chars[index + k] != needleChars[k] { return false }
        return true
    }

    while i < n {
        if blockDepth > 0 {
            if has("/*", at: i) { blockDepth += 1; i += 2 }
            else if has("*/", at: i) { blockDepth -= 1; i += 2 }
            else {
                if chars[i] == "\n" { out.append("\n") }
                i += 1
            }
            continue
        }

        if has("//", at: i) {
            while i < n, chars[i] != "\n" { i += 1 }
            continue
        }

        if has("/*", at: i) {
            blockDepth = 1
            i += 2
            continue
        }

        if has("\"\"\"", at: i) {
            i += 3
            while i < n, !has("\"\"\"", at: i) {
                if chars[i] == "\n" { out.append("\n") }
                i += 1
            }
            i = min(i + 3, n)
            continue
        }

        if has("#\"", at: i) {
            i += 2
            while i < n, !has("\"#", at: i) {
                if chars[i] == "\n" { out.append("\n") }
                i += 1
            }
            i = min(i + 2, n)
            continue
        }

        if chars[i] == "\"" {
            i += 1
            while i < n, chars[i] != "\"" {
                if chars[i] == "\\", i + 1 < n { i += 2; continue }
                if chars[i] == "\n" { out.append("\n") }
                i += 1
            }
            i = min(i + 1, n)
            continue
        }

        out.append(chars[i])
        i += 1
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
        let source = strippingCommentsAndLiterals(try String(contentsOf: url, encoding: .utf8))
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
            "A pure enumeration helper that deliberately does not prompt, so listing "
            + "composes without side effects. No production caller exists yet, so "
            + "nothing currently guarantees access is ensured before it runs — "
            + "re-audit this entry when AutomationHost.listTargets() (Task 7) lands.",
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
        let source = strippingCommentsAndLiterals(try String(contentsOf: url, encoding: .utf8))
        guard source.contains("SCShareableContent.") else { continue }
        if allowed[name] != nil { continue }
        if source.contains("ScreenRecordingAccess.ensureGranted")
            || source.contains("CGRequestScreenCaptureAccess") { continue }
        offenders.append("\(name): enumerates SCShareableContent without ensuring access")
    }
    #expect(offenders.isEmpty, "\(offenders)")
}

@Test("The scanner removes mentions but keeps real call sites")
func scannerRemovesMentionsNotCalls() {
    // Each of these previously defeated the guard, or would have.
    let cases: [(String, Bool, String)] = [
        ("let x = CGRequestScreenCaptureAccess()", true,  "a real call must survive"),
        ("// call CGRequestScreenCaptureAccess() here", false, "line comment"),
        ("/* CGRequestScreenCaptureAccess() */", false, "block comment"),
        ("/* /* CGRequestScreenCaptureAccess() */ */", false, "NESTED block comment"),
        ("let s = \"call CGRequestScreenCaptureAccess() first\"", false, "string literal"),
        ("let s = \"\"\"\nCGRequestScreenCaptureAccess()\n\"\"\"", false, "multiline string"),
        ("let s = \"an escaped \\\" quote\" ; CGRequestScreenCaptureAccess()",
         true, "a call after a literal containing an escaped quote must survive"),
        (##"let s = #"CGRequestScreenCaptureAccess()"#"##, false, "raw string"),
    ]
    for (source, shouldSurvive, why) in cases {
        let stripped = strippingCommentsAndLiterals(source)
        #expect(stripped.contains("CGRequestScreenCaptureAccess") == shouldSurvive, "\(why): \(source)")
    }
}
