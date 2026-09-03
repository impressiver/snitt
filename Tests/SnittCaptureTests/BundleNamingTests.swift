import Testing
import Foundation
@testable import SnittCapture
import SnittDocument

@Test("A branch and commit name the bundle")
func branchAndCommitNameTheBundle() {
    let name = BundleNaming.filename(
        git: GitContext(branch: "feature/markers", commit: "a1b2c3d"), timestamp: 100)
    #expect(name == "feature-markers-a1b2c3d.snitt")
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
                                  timestamp: 1) == "a1b2c3d.snitt")
}

@Test("A branch with no commit still names the bundle")
func branchOnlyNamesTheBundle() {
    #expect(BundleNaming.filename(git: GitContext(branch: "main", commit: nil),
                                  timestamp: 1) == "main.snitt")
}
