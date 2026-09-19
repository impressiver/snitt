// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import snitt_cli
import SnittAutomation

/// The stderr half of D107, which is the half a person reads.
///
/// `emit(report)` already prints the JSON. These guard the prose beside it,
/// for the same reason `ExportNoteTests` guards `exportNote`: the JSON carried
/// `maxSizeMet: false` honestly while the line a person saw said nothing about
/// it at all.
@Suite
struct TranscriptNoteTests {

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

    @Test("A recording with no transcript says so in words")
    func noTranscriptReadsAsAbsent() {
        // DISCRIMINATES AGAINST: one rendering for both states. "0 words in 0
        // lines" is what a transcribed-to-silence recording says, and reading
        // it for a recording nobody has transcribed sends a person looking for
        // a recogniser bug instead of running the recogniser.
        let text = transcriptNote(report(locale: nil, captions: false))
        #expect(text.lowercased().contains("no transcript"))
        #expect(!text.contains("0 word"))
    }

    @Test("Captions being off is stated, not left to be discovered on playback")
    func captionsOffIsAnnounced() {
        // DISCRIMINATES AGAINST: printing the lines and stopping. The words
        // are in the bundle and in no export, and the only way to find that
        // out otherwise is to export and watch, which is the thing an agent
        // cannot do.
        let text = transcriptNote(report(locale: "en-US", captions: false,
                                         lines: [line("hello")]))
        #expect(text.lowercased().contains("captions are off"))
        #expect(text.contains("--captions"), "does not say how to fix it")

        // And silent when there is nothing to caption or captions are already
        // on: a warning that fires every time is a warning nobody reads.
        #expect(!transcriptNote(report(locale: "en-US", captions: true,
                                       lines: [line("hello")]))
            .lowercased().contains("captions are off"))
        #expect(!transcriptNote(report(locale: "en-US", captions: false))
            .lowercased().contains("captions are off"))
    }

    @Test("A muted line and a written line are marked as what they are")
    func linesCarryTheirOrigin() {
        // Both facts change what a reader should do about the line, and
        // neither is recoverable from the text of the line itself.
        let text = transcriptNote(report(locale: "en-US", captions: true, lines: [
            line("heard but silenced", audible: false),
            line("written by an agent", authored: true),
        ]))
        #expect(text.contains("muted"))
        #expect(text.contains("written"))
    }

    @Test("A narration write warns when nothing will ever show it")
    func narrationNoteWarnsWhenCaptionsAreOff() {
        // The write-side twin of `captionsOffIsAnnounced`, and the sharper
        // one: Snitt does not speak a written line, so with captions off this
        // call succeeded and changed nothing anybody will see.
        let quiet = NarrationSummary(bundlePath: "/tmp/x.snitt", wordCount: 4,
                                     startSeconds: 1, endSeconds: 2.2,
                                     totalWordCount: 4, captionsEnabled: false)
        #expect(narrationNote(quiet).lowercased().contains("captions are off"))
        #expect(narrationNote(quiet).contains("--captions"))

        let loud = NarrationSummary(bundlePath: "/tmp/x.snitt", wordCount: 4,
                                    startSeconds: 1, endSeconds: 2.2,
                                    totalWordCount: 4, captionsEnabled: true)
        #expect(!narrationNote(loud).lowercased().contains("captions are off"))
        // And the line's span is reported either way, an agent placing a
        // second line needs to know where the first one ends.
        #expect(narrationNote(loud).contains("2.20s"))
    }
}

/// D108's stderr half: a listing a person can act on.
@Suite
struct RecordingsNoteTests {

    private func recording(_ name: String, bytes: Int, age: Double,
                           outcome: String?) -> RecordingSummary {
        RecordingSummary(path: "/tmp/Snitt/\(name).snitt", byteSize: bytes,
                         ageSeconds: age, createdAt: Date(), initiator: "agent",
                         outcome: outcome, durationSeconds: 12)
    }

    @Test("A truncated listing says it is truncated")
    func truncationIsStated() {
        // DISCRIMINATES AGAINST: printing the rows and their count. A reader
        // who takes two rows for the whole directory deletes the wrong things,
        // or concludes the disk is fine when it is not.
        let list = RecordingList(directory: "/tmp/Snitt", total: 9,
                                 recordings: [recording("a", bytes: 1_000_000,
                                                        age: 30, outcome: nil)],
                                 totalByteSize: 9_000_000)
        let text = recordingsNote(list)
        #expect(text.contains("9 recording"))
        #expect(text.lowercased().contains("showing the newest"))
        // And the byte total is the DIRECTORY's, not the listed row's.
        #expect(text.contains("9.0 MB"))
    }

    @Test("Capped recordings are called out, not just listed")
    func cappedIsCalledOut() {
        // The finding this closes: a capped bundle is a full-resolution video
        // nobody asked for and nobody has watched. It reads like any other row
        // unless the summary says otherwise.
        let list = RecordingList(
            directory: "/tmp/Snitt", total: 2,
            recordings: [recording("orphan", bytes: 500_000_000, age: 7200,
                                   outcome: "capped"),
                         recording("demo", bytes: 1_000_000, age: 60,
                                   outcome: "completed")],
            totalByteSize: 501_000_000)
        let text = recordingsNote(list)
        #expect(text.contains("CAPPED"))
        #expect(text.contains("500.0 MB"))
        #expect(text.contains("2h ago"))
    }

    @Test("An empty directory says where it looked")
    func emptyNamesTheDirectory() {
        // "No recordings" alone leaves a person unable to tell an empty
        // directory from the wrong directory, and the output location is a
        // setting they may have changed.
        let text = recordingsNote(RecordingList(directory: "/tmp/Snitt", total: 0,
                                                recordings: [], totalByteSize: 0))
        #expect(text.contains("/tmp/Snitt"))
    }

    @Test("Ages read in the largest unit that still says something")
    func agesAreHuman() {
        #expect(age(30) == "30s ago")
        #expect(age(600) == "10m ago")
        #expect(age(7200) == "2h ago")
        #expect(age(172800) == "2d ago")
    }
}
