// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittAutomation

/// A plausible wrong implementation this whole file discriminates against:
/// forwarding the input untouched, exactly what `snitt-cli` did before
/// finding #3 of the M3c whole-branch review (paths resolved in the wrong
/// process — the app's cwd, not the caller's). Every test below constructs
/// its input so that the verbatim-passthrough answer visibly differs from
/// the correct one.
private func verbatim(_ path: String, workingDirectory: String) -> String { path }

@Test("A relative path is resolved against the caller's working directory")
func relativePathResolvedAgainstWorkingDirectory() {
    let resolved = PathResolver.resolve("demo.mp4", workingDirectory: "/tmp/snitt-test-cwd")
    #expect(resolved == "/tmp/snitt-test-cwd/demo.mp4")
    #expect(resolved != verbatim("demo.mp4", workingDirectory: "/tmp/snitt-test-cwd"))
}

@Test("An absolute path passes through unaffected by workingDirectory")
func absolutePathPassesThroughUnchanged() {
    // `workingDirectory` is deliberately a DIFFERENT tree than the path, so
    // an implementation that always joins with workingDirectory regardless
    // of the input's own absoluteness (rather than special-casing it, or
    // relying on `URL`'s own "an absolute component replaces the base"
    // behavior) would visibly fail this.
    let resolved = PathResolver.resolve("/tmp/abs/path/demo.mp4", workingDirectory: "/some/unrelated/dir")
    #expect(resolved == "/tmp/abs/path/demo.mp4")
}

@Test("A tilde-prefixed path expands to the user's home directory, not a literal ~ subdirectory")
func tildePrefixedPathExpandsToHome() {
    // Pinning the actual, chosen behavior: `~` is expanded via
    // `NSString.expandingTildeInPath` before anything else. A plausible
    // wrong implementation treats an un-expanded "~/demo.mp4" as an
    // ordinary relative path, landing it inside `workingDirectory` as a
    // literal "~" directory component — a directory that generally does not
    // exist, and never what the caller meant.
    let resolved = PathResolver.resolve("~/demo.mp4", workingDirectory: "/some/unrelated/dir")
    #expect(resolved == NSHomeDirectory() + "/demo.mp4")
    #expect(!resolved.contains("unrelated"),
            "a tilde path must not be treated as relative to workingDirectory")
}

@Test("The empty string resolves to workingDirectory itself")
func emptyStringResolvesToWorkingDirectory() {
    // Pinning `URL`'s own behavior for a zero-length relative path
    // component, rather than leaving it as an accident nobody verified.
    let resolved = PathResolver.resolve("", workingDirectory: "/tmp/snitt-test-cwd")
    #expect(resolved == "/tmp/snitt-test-cwd")
}

@Test("A path containing .. is resolved relative to workingDirectory, not left as a literal .. segment")
func dotDotIsResolvedRelativeToWorkingDirectory() {
    let resolved = PathResolver.resolve("../demo.mp4", workingDirectory: "/tmp/snitt-test-cwd/nested")
    #expect(resolved == "/tmp/snitt-test-cwd/demo.mp4")
    #expect(resolved != verbatim("../demo.mp4", workingDirectory: "/tmp/snitt-test-cwd/nested"))
}

@Test("An absolute path containing .. is standardized, collapsing the .. segment")
func absoluteDotDotIsCollapsed() {
    let resolved = PathResolver.resolve("/tmp/x/../y.mp4", workingDirectory: "/ignored")
    #expect(resolved == "/tmp/y.mp4")
}
