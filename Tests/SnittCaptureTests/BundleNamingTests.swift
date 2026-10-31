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

// MARK: - The recorded application (D1)
//
// The app name leads the bundle name, and the recorded window's TITLE is
// deliberately absent. `RecordingCoordinator.openEditor(for:)` already
// redacts this filename from error messages because it embeds the git
// branch, and records a measured leak of it through `NSError.userInfo`'s
// `NSFilePath` into `snitt diagnostics export` — which people attach to
// public support threads. `DiagnosticsBundle.redactingTarget` salted-hashes
// the window title for that same export path, and `RecordingMetadata`
// carries no title field at all. So the title is the one field this
// codebase guards hardest, and the filename is a known leak surface; an app
// name ("Safari", "Xcode") is a fixed, low-entropy string and is not.

@Test("The recorded application leads the bundle name")
func applicationLeadsTheName() {
    let name = BundleNaming.filename(
        app: "Safari",
        git: GitContext(branch: "main", commit: "a1b2c3d"), timestamp: 100)
    #expect(name == "Safari-main-a1b2c3d-100.snitt")
}

@Test("The application names the bundle with no git context")
func applicationNamesTheBundleWithoutGit() {
    // "Snitt" is the no-context fallback, so an app name has to displace it
    // rather than sit beside it.
    #expect(BundleNaming.filename(app: "Xcode", git: nil, timestamp: 7)
            == "Xcode-7.snitt")
}

@Test("Spaces in an application name are sanitised")
func applicationSpacesAreSanitised() {
    let name = BundleNaming.filename(
        app: "Visual Studio Code",
        git: GitContext(branch: "main", commit: "a1b2c3d"), timestamp: 1)
    #expect(name == "Visual-Studio-Code-main-a1b2c3d-1.snitt")
}

@Test("A punctuated application name produces no hyphen runs or trailing hyphen")
func punctuatedApplicationNameCollapses() {
    // Real shape: "Adobe Photoshop (Beta)" sanitises to
    // "Adobe-Photoshop--Beta-" — a double hyphen and a trailing one, both
    // ugly in a name a human reads in Finder. Collapsed for the APP part
    // only, deliberately: branch and commit keep their existing byte-exact
    // behaviour (see `noApplicationIsByteIdenticalToTheOldName`).
    let name = BundleNaming.filename(
        app: "Adobe Photoshop (Beta)",
        git: GitContext(branch: "main", commit: "a1b2c3d"), timestamp: 1)
    #expect(name == "Adobe-Photoshop-Beta-main-a1b2c3d-1.snitt")
    #expect(!name.contains("--"))
}

@Test("An application name that sanitises to nothing falls back to the git name")
func emptyApplicationNameFallsBack() {
    // An app whose localizedName is punctuation alone is not a real case, but
    // an EMPTY or whitespace one is: `SCRunningApplication.applicationName`
    // is a plain String that has been observed empty for helper processes.
    #expect(BundleNaming.filename(
        app: "   ", git: GitContext(branch: "main", commit: "a1b2c3d"),
        timestamp: 1) == "main-a1b2c3d-1.snitt")
}

@Test("A long application name is capped without starving the branch or commit")
func longApplicationNameIsCapped() {
    let name = BundleNaming.filename(
        app: String(repeating: "A", count: 300),
        git: GitContext(branch: "release", commit: "a1b2c3d"), timestamp: 1)
    #expect(name.utf8.count <= 210, "got \(name.utf8.count) bytes")
    #expect(name.contains("a1b2c3d"), "the commit must survive an overlong app name")
    #expect(name.contains("release"), "the branch must survive an overlong app name")
}

@Test("A long branch is truncated while the application and commit survive")
func longBranchTruncatesBeforeTheApplication() {
    // THE REGRESSION TEST FOR THE POSITIONAL BUG.
    //
    // The old truncation indexed a two-slot `[branch, commit]` array and
    // branched on `parts.count == 2`, truncating `parts[0]`. Prepending the
    // app made `parts[0]` the APP, so "truncate the branch first" silently
    // became "truncate the app first" — the app name would have been shredded
    // while a 400-character branch sailed through. A mutant that reverts to
    // positional truncation fails here and nowhere else in this file.
    let name = BundleNaming.filename(
        app: "Safari",
        git: GitContext(branch: String(repeating: "x", count: 400), commit: "a1b2c3d"),
        timestamp: 1)
    #expect(name.utf8.count <= 210, "got \(name.utf8.count) bytes")
    #expect(name.hasPrefix("Safari-"), "the app name is not the part that gets truncated")
    #expect(name.contains("a1b2c3d"), "the commit is never truncated")
    #expect(name.hasSuffix("-1.snitt"), "the timestamp is never truncated")
}

@Test("No application name is byte-identical to the old name")
func noApplicationIsByteIdenticalToTheOldName() {
    // The `app` parameter defaults to nil so a display recording, or any
    // caller that cannot name an app, keeps exactly the name it had before
    // this change. Pinned explicitly rather than left to the older tests
    // above, because this is the promise the restructure had to keep while
    // rewriting the budget arithmetic underneath them.
    #expect(BundleNaming.filename(
        app: nil, git: GitContext(branch: "feature/markers", commit: "a1b2c3d"),
        timestamp: 100) == "feature-markers-a1b2c3d-100.snitt")
    #expect(BundleNaming.filename(app: nil, git: nil, timestamp: 42)
            == "Snitt-42.snitt")
}
