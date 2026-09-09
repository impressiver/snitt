// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

private func runner(_ replies: [String: String?]) -> CommandRunner {
    CommandRunner { _, args, _ in replies[args.joined(separator: " ")] ?? nil }
}

@Test("A repository yields its branch and short commit")
func resolvesBranchAndCommit() {
    let git = runner([
        "rev-parse --abbrev-ref HEAD": "feature/markers",
        "rev-parse --short HEAD": "a1b2c3d",
    ])
    let context = GitContextResolver.resolve(in: URL(fileURLWithPath: "/x"), runner: git)
    #expect(context?.branch == "feature/markers")
    #expect(context?.commit == "a1b2c3d")
}

@Test("A directory outside any repository yields nil, not an empty context")
func nonRepositoryYieldsNil() {
    // nil and GitContext(branch: nil, commit: nil) mean different things in
    // meta.json: absent versus "we looked and found nothing". Absent is correct.
    #expect(GitContextResolver.resolve(in: URL(fileURLWithPath: "/x"),
                                       runner: runner([:])) == nil)
}

@Test("Detached HEAD reports the commit and no branch")
func detachedHeadHasNoBranch() {
    // `rev-parse --abbrev-ref HEAD` prints the literal "HEAD" when detached.
    // Recording that as a branch named HEAD would be a lie in every bundle
    // made during a bisect or a CI checkout.
    let git = runner([
        "rev-parse --abbrev-ref HEAD": "HEAD",
        "rev-parse --short HEAD": "deadbee",
    ])
    let context = GitContextResolver.resolve(in: URL(fileURLWithPath: "/x"), runner: git)
    #expect(context?.branch == nil)
    #expect(context?.commit == "deadbee")
}

@Test("Output is trimmed of the trailing newline git always emits")
func trimsTrailingNewline() {
    let git = runner([
        "rev-parse --abbrev-ref HEAD": "main\n",
        "rev-parse --short HEAD": "a1b2c3d\n",
    ])
    #expect(GitContextResolver.resolve(in: URL(fileURLWithPath: "/x"),
                                       runner: git)?.branch == "main")
}

@Test("A commit with no branch still produces a context")
func commitAloneIsEnough() {
    let git = runner(["rev-parse --short HEAD": "a1b2c3d"])
    #expect(GitContextResolver.resolve(in: URL(fileURLWithPath: "/x"),
                                       runner: git)?.commit == "a1b2c3d")
}
