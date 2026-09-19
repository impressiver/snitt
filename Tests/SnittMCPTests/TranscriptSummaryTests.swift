// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import snitt_mcp
import SnittAutomation

/// D107 on the MCP side: both halves of a tool result, prose and object.
@Suite
struct TranscriptSummaryTests {

    private func report(locale: String?, captions: Bool,
                        lines: [TranscriptReport.Line] = []) -> TranscriptReport {
        TranscriptReport(bundlePath: "/tmp/x.snitt", locale: locale,
                         wordCount: lines.count, authoredWordCount: 0,
                         captionsEnabled: captions, lines: lines)
    }

    private func line(_ text: String, authored: Bool = false,
                      audible: Bool = true) -> TranscriptReport.Line {
        TranscriptReport.Line(startSeconds: 1.5, endSeconds: 2, track: "microphone",
                              authored: authored, audible: audible, text: text)
    }

    @Test("The transcript arrives as an object, not only as a sentence")
    func transcriptHasStructuredContent() throws {
        // D103's rule, applied to the two responses added after it. Rendering
        // these as prose alone would put an agent back to pattern-matching
        // sentences for the times it needs to place its next line.
        let structured = try #require(structuredContent(
            .transcriptRead(report(locale: "en-US", captions: true,
                                   lines: [line("hello there")]))))
        #expect(structured["locale"] as? String == "en-US")
        #expect(structured["captionsEnabled"] as? Bool == true)
        let lines = try #require(structured["lines"] as? [[String: Any]])
        #expect(lines.first?["text"] as? String == "hello there")
        #expect(lines.first?["startSeconds"] as? Double == 1.5)
    }

    @Test("A narration write arrives as an object too")
    func narrationHasStructuredContent() throws {
        let structured = try #require(structuredContent(
            .narrationAdded(NarrationSummary(
                bundlePath: "/tmp/x.snitt", wordCount: 3, startSeconds: 4,
                endSeconds: 4.9, totalWordCount: 7, captionsEnabled: false))))
        #expect(structured["wordCount"] as? Int == 3)
        #expect(structured["totalWordCount"] as? Int == 7)
        #expect(structured["captionsEnabled"] as? Bool == false)
    }

    @Test("Captions being off is said in the prose, both when reading and writing")
    func captionsOffIsAnnounced() {
        // DISCRIMINATES AGAINST: prose that reports only what was written.
        // Snitt does not SPEAK a written line, so with captions off the call
        // succeeded and changed nothing a viewer will ever see, and the agent
        // has no way to discover that, because it cannot watch the export.
        let read = transcriptSummary(report(locale: "en-US", captions: false,
                                            lines: [line("hello")]))
        #expect(read.lowercased().contains("captions are off"))
        #expect(read.contains("captions: true"), "does not say how to fix it")

        let written = narrationSummary(NarrationSummary(
            bundlePath: "/tmp/x.snitt", wordCount: 1, startSeconds: 0,
            endSeconds: 0.3, totalWordCount: 1, captionsEnabled: false))
        #expect(written.lowercased().contains("captions are off"))
        #expect(written.contains("captions: true"))

        // Silent when captions are already on, so the warning stays worth
        // reading.
        #expect(!transcriptSummary(report(locale: "en-US", captions: true,
                                          lines: [line("hello")]))
            .lowercased().contains("captions are off"))
    }

    @Test("No transcript reads as absent, not as silence")
    func noTranscriptReadsAsAbsent() {
        let text = transcriptSummary(report(locale: nil, captions: false))
        #expect(text.lowercased().contains("no transcript"))
        #expect(!text.contains("0 word"))
    }

    @Test("Both frontends warn about captions in the same terms")
    func theTwoFrontendsAgree() {
        // §4.8: the CLI and the MCP server must not diverge. The wording
        // differs, one names a flag, the other names a parameter, but the
        // CLAIM has to be the same, or an agent on one surface learns
        // something an agent on the other does not.
        let summary = NarrationSummary(bundlePath: "/tmp/x.snitt", wordCount: 1,
                                       startSeconds: 0, endSeconds: 0.3,
                                       totalWordCount: 1, captionsEnabled: false)
        #expect(narrationSummary(summary).lowercased().contains("captions are off"))
        #expect(narrationSummary(summary).contains("snitt_export"))
    }
}
