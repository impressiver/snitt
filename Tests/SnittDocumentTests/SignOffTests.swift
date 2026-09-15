// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation

/// The contribution terms, as documents (D98).
///
/// These are the only assertions this change can have: it creates no symbol,
/// so an absence marker naming a file would be checked by
/// `PlanClaimsTests.isDeclared` — which greps Swift declarations under
/// `Sources/` — and would therefore pass for ever without once having been
/// true.
///
/// What they protect is a real failure mode. The inbound licence is declared
/// in prose and nowhere else; a contributor's grant is only as good as the
/// sentence stating it, and a well-meaning edit that tidies that sentence away
/// leaves every contribution after it arriving under terms nobody wrote down.
@Suite
struct SignOffTests {

    private func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    /// The document as one long line, with blockquote markers removed.
    ///
    /// Markdown wraps for line length, so "Apache License, Version 2.0" is
    /// split across two lines inside a `>` quote. A test matching the raw text
    /// fails whenever anybody reflows a paragraph — which makes it a test
    /// about formatting wearing the costume of a test about licensing, and the
    /// kind that gets weakened rather than fixed the third time it cries wolf.
    private func prose(_ path: String) throws -> String {
        try read(path)
            .replacingOccurrences(of: "\n> ", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    @Test("The dual inbound licence is actually declared, in both licences' names")
    func inboundLicenceIsStated() throws {
        // BOTH names. A DCO on its own sets inbound equal to outbound and
        // grants nothing extra, so a project that swapped the CLA for a bare
        // DCO would still need unanimous permission to relicense — the exact
        // problem the CLA existed to avoid, and the usual mistake. The second
        // licence IS the mechanism, so a file naming only one of them has
        // silently reverted this decision.
        let contributing = try prose("CONTRIBUTING.md")
        // Reduced to Bools BEFORE asserting, so a failure prints `false`
        // rather than the whole document.
        //
        // Not tidiness. `Scripts/mutate.sh` read its verdict out of the test
        // log, a dumped CONTRIBUTING.md carried the sentence "Only the `Test
        // run with N tests ... passed` line is trustworthy", and the script
        // matched that and called a killed mutant a survivor. The script is
        // fixed; an assertion that pastes a whole file into the log is still
        // a landmine for the next tool that reads one.
        let declaresMPL = contributing.contains("Mozilla Public License 2.0")
        let declaresApache = contributing.contains("Apache License, Version 2.0")
        // And stated as a GRANT, not merely mentioned: "Snitt is licensed
        // under the MPL" already contains one of those names.
        let grants = contributing.contains("shall be licensed")
        #expect(declaresMPL)
        #expect(declaresApache,
                "the additional grant is gone — the DCO now grants nothing extra")
        #expect(grants, "the inbound licence is named but never granted")
    }

    @Test("The DCO text is present and unedited")
    func dcoIsVerbatim() throws {
        // Reproduced verbatim or not reproduced at all: a DCO paraphrased into
        // the project's own voice is not the DCO anyone recognises, and its
        // clauses are what the sign-off points at.
        let contributing = try prose("CONTRIBUTING.md")
        #expect(contributing.contains("Developer Certificate of Origin"))
        #expect(contributing.contains("Version 1.1"))
        // The four clauses, by their distinguishing phrases rather than by
        // their letters — "(a)" appears in plenty of prose.
        #expect(contributing.contains("have the right to submit it under the open source license"))
        #expect(contributing.contains("is covered under an appropriate open source"))
        #expect(contributing.contains("person who certified (a), (b) or (c)"))
        #expect(contributing.contains("maintained indefinitely and may be redistributed"))
    }

    @Test("Contributors are told how to sign off")
    func signOffIsExplained() throws {
        // The agreement is worthless if nobody performs it. `-s` is the whole
        // instruction and it is not guessable.
        #expect(try prose("CONTRIBUTING.md").contains("git commit -s"))
        #expect(try prose(".github/pull_request_template.md").contains("git commit -s"),
                "the PR checklist no longer asks for a sign-off")
    }

    @Test("Nothing still asks contributors to agree to a CLA")
    func theCLAIsNotStillRequired() throws {
        // The failure this catches is a partial migration: the agreement
        // retired in one file and still demanded in another, so a contributor
        // is told both that there is no CLA and that they must accept one.
        for path in ["CONTRIBUTING.md", "README.md", ".github/pull_request_template.md"] {
            let text = try prose(path)
            #expect(!text.contains("agree to [`CLA.md`]"), "\(path) still requires the CLA")
            #expect(!text.contains("agreeing to [`CLA.md`]"), "\(path) still requires the CLA")
            #expect(!text.contains("agreeing to the [CLA]"), "\(path) still requires the CLA")
        }
    }

    @Test("The retired CLA explains itself rather than 404ing")
    func theTombstonePointsSomewhere() throws {
        // Kept rather than deleted: old pull requests, issues and commit
        // messages link to it, and a dead link leaves a reader unable to tell
        // whether the terms they agreed to still apply.
        let cla = try prose("CLA.md")
        #expect(cla.contains("retired"))
        #expect(cla.contains("CONTRIBUTING.md"), "the tombstone does not say where to go instead")
        // And it no longer READS as an agreement — a file still opening with
        // "By submitting a contribution you agree to the following" is one a
        // contributor can reasonably believe is in force.
        #expect(!cla.contains("By submitting a contribution you agree to the following"),
                "the tombstone still contains the agreement it is supposed to retire")
    }

    @Test("The reason it went is written down, not just the fact")
    func theReasoningSurvives() throws {
        // Decisions are sticky, not frozen. Someone will eventually propose
        // putting a CLA back to enable an App Store build; the finding that
        // kills that argument — MPL-2.0 already ships there — has to be
        // readable at the point the question is asked.
        let cla = try prose("CLA.md")
        #expect(cla.contains("App Store"))
        #expect(cla.contains("MPL"))
    }
}
