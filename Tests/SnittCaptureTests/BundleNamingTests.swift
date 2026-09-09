// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittCapture
import SnittDocument

@Test("A branch and commit name the bundle")
func branchAndCommitNameTheBundle() {
    // The timestamp is part of the name even WITH git context. This test used
    // to pin "feature-markers-a1b2c3d.snitt" as correct, which made the name a
    // pure function of branch+commit — and so made every second recording of
    // the same commit fail on `SnittBundle.alreadyExists`, permanently.
    let name = BundleNaming.filename(
        git: GitContext(branch: "feature/markers", commit: "a1b2c3d"), timestamp: 100)
    #expect(name == "feature-markers-a1b2c3d-100.snitt")
}

@Test("Two recordings on the same commit do not collide")
func sameCommitTwiceProducesDistinctNames() {
    // The discriminating check. Record, stop, edit, record again without
    // committing — the ordinary loop — and pre-fix both names were identical,
    // so the second `SnittBundle(creatingAt:)` threw `.alreadyExists` and the
    // agent got exit 16 naming a filesystem enum, forever, until a human moved
    // the file off the Desktop.
    let git = GitContext(branch: "feat/m3a-capture-context", commit: "a1b2c3d")
    let first = BundleNaming.filename(git: git, timestamp: 1_788_464_616)
    let second = BundleNaming.filename(git: git, timestamp: 1_788_464_700)
    #expect(first != second,
            "the second recording on an unchanged working tree must get its own bundle")
    #expect(first == "feat-m3a-capture-context-a1b2c3d-1788464616.snitt")
}

@Test("A branch named \".\" does not produce a hyphen-led bundle name")
func degenerateBranchNameIsNotHyphenLed() {
    let name = BundleNaming.filename(git: GitContext(branch: ".", commit: "a1b2c3d"),
                                     timestamp: 7)
    #expect(name == "a1b2c3d-7.snitt")
}

@Test("A slash in a branch name never becomes a path separator")
func slashesAreReplaced() {
    // The name is appended to a directory URL. A branch called "feature/x"
    // would otherwise write into a "feature" SUBDIRECTORY that does not exist,
    // and the bundle creation would fail — with intermediate directories
    // deliberately disabled, this fails loudly rather than scattering files.
    let name = BundleNaming.filename(
        git: GitContext(branch: "a/b/c", commit: "d"), timestamp: 1)
    #expect(!name.contains("/"))
}

@Test("No git context falls back to the timestamped name")
func noGitFallsBackToTimestamp() {
    #expect(BundleNaming.filename(git: nil, timestamp: 1788464616)
            == "Snitt-1788464616.snitt")
}

@Test("A commit with no branch still names the bundle")
func commitOnlyNamesTheBundle() {
    #expect(BundleNaming.filename(git: GitContext(branch: nil, commit: "a1b2c3d"),
                                  timestamp: 1) == "a1b2c3d-1.snitt")
}

@Test("A branch with no commit still names the bundle")
func branchOnlyNamesTheBundle() {
    #expect(BundleNaming.filename(git: GitContext(branch: "main", commit: nil),
                                  timestamp: 1) == "main-1.snitt")
}

@Test("A branch beginning with a dot does not produce a hidden bundle")
func leadingDotIsStripped() {
    let name = BundleNaming.filename(
        git: GitContext(branch: ".hidden-wip", commit: "a1b2c3d"), timestamp: 1)
    #expect(!name.hasPrefix("."),
            "a dot-prefixed bundle is hidden by Finder and ls — the user would see nothing where their recording should be")
}

@Test("Dots inside a branch name are preserved")
func interiorDotsSurvive() {
    // release.2 and v1.2 are ordinary branch names; only a LEADING dot hides.
    let name = BundleNaming.filename(
        git: GitContext(branch: "release.2", commit: "a1b2c3d"), timestamp: 1)
    #expect(name == "release.2-a1b2c3d-1.snitt")
}

@Test("A very long branch name is truncated to a safe filename length")
func longBranchNameIsTruncated() {
    let longBranch = String(repeating: "x", count: 400)
    let name = BundleNaming.filename(
        git: GitContext(branch: longBranch, commit: "a1b2c3d"), timestamp: 1)
    #expect(name.utf8.count <= 210, "expected a truncated name, got \(name.utf8.count) bytes")
    #expect(name.hasSuffix(".snitt"))
    #expect(name.contains("a1b2c3d"), "the commit — the more identifying half — must survive truncation")
}
