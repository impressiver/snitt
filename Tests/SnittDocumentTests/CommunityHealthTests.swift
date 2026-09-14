// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import Testing

/// The files a public repository is read through, and the wiki source.
///
/// All of it is text nothing else validates. A malformed issue form does not
/// error — GitHub silently stops offering it, and the first sign is a bug
/// report arriving with no version in it. A wiki link that points at nothing
/// renders as an invitation to create the page. Both fail in the direction of
/// looking fine.
///
/// Lives in SnittDocumentTests rather than SnittAppTests because that target
/// runs in CI; SnittAppTests hangs on a headless runner. These checks are pure
/// text and cost milliseconds.
@Suite
struct CommunityHealthTests {

    private func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    @Test("Every file a public repository is judged by is present")
    func communityFilesExist() {
        // GitHub's own community profile checks for these, and each answers a
        // question a newcomer asks before they read any code: may I use this,
        // how do I help, what happens if I find something dangerous, and what
        // behaviour is expected.
        for path in ["LICENSE", "README.md", "CONTRIBUTING.md", "CODE_OF_CONDUCT.md",
                     "SECURITY.md", "CLA.md", "THIRD-PARTY-NOTICES.md",
                     ".github/CODEOWNERS", ".github/pull_request_template.md",
                     ".github/ISSUE_TEMPLATE/config.yml",
                     ".github/ISSUE_TEMPLATE/bug_report.yml",
                     ".github/ISSUE_TEMPLATE/feature_request.yml"] {
            #expect(FileManager.default.fileExists(atPath: path), "missing \(path)")
        }
    }

    @Test("Issue forms declare the keys GitHub needs to offer them")
    func issueFormsAreWellFormed() throws {
        // An issue form missing `name` or `description` is not an error: GitHub
        // declines to offer it and says nothing. The template then exists, is
        // committed, is never seen, and every report arrives freehand.
        for form in ["bug_report", "feature_request"] {
            let text = try read(".github/ISSUE_TEMPLATE/\(form).yml")
            #expect(text.contains("name:"), "\(form) has no name:")
            #expect(text.contains("description:"), "\(form) has no description:")
            #expect(text.contains("body:"), "\(form) has no body:")
        }

        let config = try read(".github/ISSUE_TEMPLATE/config.yml")
        // Blank issues OFF is what makes the forms load-bearing rather than
        // optional: with them on, "Open a blank issue" sits under the forms and
        // is the faster path for anyone in a hurry.
        #expect(config.contains("blank_issues_enabled: false"))
        // The private security route must be reachable from the place someone
        // goes to file a bug. A public issue about a vulnerability cannot be
        // unfiled.
        #expect(config.contains("security/advisories/new"),
                "config.yml does not offer the private security route")
    }

    @Test("The bug form asks for the three things every report needs")
    func bugFormAsksForVersions() throws {
        // Without these the first reply is always the same three questions, and
        // the round trip costs a day. "How installed" earns its place: a build
        // from source is unsigned, so macOS treats a rebuild as a different app
        // and silently drops its permissions — which looks exactly like a bug.
        let form = try read(".github/ISSUE_TEMPLATE/bug_report.yml")
        for field in ["snitt-version", "macos-version", "how-installed"] {
            #expect(form.contains("id: \(field)"), "the bug form does not ask for \(field)")
        }
        #expect(form.contains("security/advisories/new"),
                "the bug form does not redirect security reports")
    }

    @Test("Every wiki page links only to pages that exist")
    func wikiLinksResolve() throws {
        // A GitHub wiki renders a link to a missing page as a live invitation
        // to create it, so a typo reads as an unwritten page rather than as a
        // mistake. Nothing else catches that.
        let directory = "docs/wiki"
        let files = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".md") }
        #expect(files.count > 5, "wiki source scan found almost nothing: \(files)")
        let pages = Set(files.map { String($0.dropLast(3)) })

        let pattern = try NSRegularExpression(pattern: #"\]\(([^)]+)\)"#)
        var dangling: [String] = []
        for file in files {
            let text = try read("\(directory)/\(file)")
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let link = String(text[range])
                // Absolute URLs and anchors are somebody else's problem.
                if link.hasPrefix("http") || link.hasPrefix("#") || link.hasPrefix("mailto:") {
                    continue
                }
                let page = link.split(separator: "#").first.map(String.init) ?? link
                if !pages.contains(page) { dangling.append("\(file) -> \(link)") }
            }
        }
        #expect(dangling.isEmpty, "wiki links to pages that do not exist:\n\(dangling.joined(separator: "\n"))")
    }

    @Test("The wiki's front page reaches every other page")
    func homeLinksEveryPage() throws {
        // A page nothing links to is a page nobody finds. The wiki has no
        // sidebar generated from the file list, so Home IS the index.
        let home = try read("docs/wiki/Home.md")
        let files = try FileManager.default.contentsOfDirectory(atPath: "docs/wiki")
            .filter { $0.hasSuffix(".md") && $0 != "Home.md" && $0 != "README.md" }
        let orphans = files
            .map { String($0.dropLast(3)) }
            .filter { !home.contains("(\($0))") }
        #expect(orphans.isEmpty, "no route from Home to: \(orphans)")
    }
}
