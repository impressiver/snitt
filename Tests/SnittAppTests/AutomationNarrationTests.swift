// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
import SnittAutomation
import SnittDocument
@testable import SnittApp

/// D107 at the seam where it actually touches a bundle.
///
/// `MCPBridgeTests` and `CommandLineParserTests` prove the two frontends BUILD
/// the right request; these prove the app then does the right thing to a real
/// `transcript.json` and a real `edit.json` on disk. Nothing here needs a
/// movie: every verb under test reads or writes a sidecar.
@Suite
struct AutomationNarrationTests {

    /// A bundle on disk with the sidecars these verbs read, and no capture.
    private func bundle(captions: Bool = false,
                        transcript: Transcript? = nil,
                        trackStates: [TrackState] = []) throws -> SnittBundle {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "narration-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        try RecordingMetadata(createdAt: Date(), initiator: .agent).write(to: bundle)
        try EventLog(events: []).write(to: bundle)
        var edl = EditDecisionList.fullRange()
        edl.showSubtitles = captions
        edl.trackStates = trackStates
        try edl.write(to: bundle)
        try transcript?.write(to: bundle)
        return bundle
    }

    private func host(agentAccess: Bool = true) -> AutomationHost {
        AutomationHost(coordinator: FakeCoordinator(),
                       settings: { AgentSettings(agentRecordingEnabled: agentAccess) },
                       onRecordingState: { _ in },
                       auditLogURL: FileManager.default.temporaryDirectory
                           .appending(path: "narration-audit-\(UUID().uuidString).jsonl"))
    }

    @MainActor
    @Test("A recording with no transcript says so, rather than reporting silence")
    func noTranscriptIsDistinctFromNoWords() async throws {
        // DISCRIMINATES AGAINST: `(try? Transcript.read(from:))?.words ?? []`,
        // the collapsing pattern this repo has now fixed at four other sidecar
        // call sites. It renders "nobody has transcribed this" and "the
        // recogniser heard nothing" as the same answer, and they want
        // different next moves. It would also swallow D60's version gate, so a
        // bundle written by a NEWER Snitt would report as empty instead of
        // telling the agent its own build is too old.
        let recording = try bundle()
        defer { try? FileManager.default.removeItem(at: recording.url) }

        let response = await host().handle(
            .transcript(bundlePath: recording.url.path), caller: nil)
        guard case .transcriptRead(let report) = response else {
            Issue.record("expected a transcript, got \(response)"); return
        }
        #expect(report.locale == nil)
        #expect(report.wordCount == 0)
        #expect(report.lines.isEmpty)
    }

    @MainActor
    @Test("A damaged transcript is refused, not reported as empty")
    func unreadableTranscriptIsRefused() async throws {
        // The other half of the same distinction: a file that EXISTS and does
        // not decode must fail loudly. `try?` here would say "this recording
        // says nothing" about a file that says something this build cannot
        // read.
        let recording = try bundle()
        defer { try? FileManager.default.removeItem(at: recording.url) }
        try Data("not json".utf8).write(to: recording.transcriptURL)

        let response = await host().handle(
            .transcript(bundlePath: recording.url.path), caller: nil)
        guard case .failure = response else {
            Issue.record("a damaged transcript decoded as something: \(response)"); return
        }
    }

    @MainActor
    @Test("Narration written by an agent is marked as authored")
    func writtenNarrationIsAuthored() async throws {
        // DISCRIMINATES AGAINST: building `TranscriptWord`s here rather than
        // through `AuthoredNarration.words`. A word written with
        // `isAuthored: false` looks identical in the pane and is a different
        // claim: `deleteWords` would then remove it by CUTTING THE FOOTAGE
        // underneath it, at a moment the agent was using only as an anchor.
        // That is the exact hazard `TranscriptWord.isAuthored` exists for.
        let recording = try bundle()
        defer { try? FileManager.default.removeItem(at: recording.url) }

        let response = await host().handle(
            .addNarration(bundlePath: recording.url.path,
                          text: "the tests are green", atSeconds: 4),
            caller: nil)
        guard case .narrationAdded(let summary) = response else {
            Issue.record("expected narration, got \(response)"); return
        }
        #expect(summary.wordCount == 4)
        #expect(summary.startSeconds == 4)

        let written = try Transcript.read(from: recording)
        #expect(written.words.count == 4)
        let everyWordIsAuthored = written.words.allSatisfy(\.isAuthored)
        let everyWordIsNarration = written.words.allSatisfy { $0.track == "voiceover" }
        #expect(everyWordIsAuthored)
        #expect(everyWordIsNarration)
        #expect(written.words.first?.start == 4)
    }

    @MainActor
    @Test("Narration joins a transcript that already has speech, in time order")
    func narrationMergesRatherThanReplaces() async throws {
        // DISCRIMINATES AGAINST: `updated.words = words`, writing the new
        // line over whatever was there. That destroys a recogniser pass with
        // no warning, and `capture.mov` cannot give it back without
        // transcribing again. Every consumer also assumes time order
        // (`TranscriptParagraphs` walks it looking for pauses), so appending
        // without sorting reads as one enormous gap and a line out of place.
        let existing = Transcript(
            words: [TranscriptWord(text: "spoken", start: 10, duration: 0.3,
                                   confidence: 0.9)],
            locale: "en-US")
        let recording = try bundle(transcript: existing)
        defer { try? FileManager.default.removeItem(at: recording.url) }

        let response = await host().handle(
            .addNarration(bundlePath: recording.url.path, text: "written",
                          atSeconds: 1),
            caller: nil)
        guard case .narrationAdded(let summary) = response else {
            Issue.record("expected narration, got \(response)"); return
        }
        #expect(summary.totalWordCount == 2)

        let written = try Transcript.read(from: recording)
        #expect(written.words.map(\.text) == ["written", "spoken"])
        #expect(written.locale == "en-US", "the recogniser's locale was overwritten")
    }

    @MainActor
    @Test("Writing narration reports whether anything will ever show it")
    func narrationReportsWhetherCaptionsAreOn() async throws {
        // DISCRIMINATES AGAINST: a summary that only counts words. Snitt does
        // not SPEAK a written line (D101 is queued, not built), so captions
        // are the only way it reaches a viewer, and `showSubtitles` is off by
        // default. Without this field the call is a complete success that
        // changes nothing anyone sees, which is the silent no-op §8 forbids.
        let off = try bundle(captions: false)
        defer { try? FileManager.default.removeItem(at: off.url) }
        guard case .narrationAdded(let quiet) = await host().handle(
            .addNarration(bundlePath: off.url.path, text: "hello", atSeconds: 0),
            caller: nil) else { Issue.record("expected narration"); return }
        #expect(quiet.captionsEnabled == false)

        let on = try bundle(captions: true)
        defer { try? FileManager.default.removeItem(at: on.url) }
        guard case .narrationAdded(let loud) = await host().handle(
            .addNarration(bundlePath: on.url.path, text: "hello", atSeconds: 0),
            caller: nil) else { Issue.record("expected narration"); return }
        #expect(loud.captionsEnabled == true)
    }

    @MainActor
    @Test("A muted track's line is reported as muted rather than hidden")
    func mutedLinesSurviveTheReport() async throws {
        // End-to-end version of `TranscriptReportTests`' own check: the mutes
        // come from this bundle's `edit.json`, so a host that passed no track
        // states, or the wrong ones, would report every line as audible and
        // an agent would caption a track nobody can hear.
        let recording = try bundle(
            transcript: Transcript(
                words: [TranscriptWord(text: "quiet", start: 0, duration: 0.3,
                                       confidence: 1)],
                locale: "en-US"),
            trackStates: [TrackState(track: "microphone", muted: true)])
        defer { try? FileManager.default.removeItem(at: recording.url) }

        guard case .transcriptRead(let report) = await host().handle(
            .transcript(bundlePath: recording.url.path), caller: nil) else {
            Issue.record("expected a transcript"); return
        }
        #expect(report.lines.count == 1)
        #expect(report.lines.first?.audible == false)
    }

    @MainActor
    @Test("Reading and writing a transcript are agent-access verbs")
    func transcriptVerbsAreGated() async throws {
        // Reading returns WHAT WAS SAID, which is the most disclosive thing in
        // a bundle; writing edits somebody's recording. The socket accepts any
        // same-user process, so neither may be reachable with agent access
        // switched off, the same reasoning that gated `.inspect`.
        let recording = try bundle()
        defer { try? FileManager.default.removeItem(at: recording.url) }
        let closed = host(agentAccess: false)

        guard case .failure(let read) = await closed.handle(
            .transcript(bundlePath: recording.url.path), caller: nil) else {
            Issue.record("a transcript was read with agent access off"); return
        }
        #expect(read.code == .consentRequired)

        guard case .failure(let write) = await closed.handle(
            .addNarration(bundlePath: recording.url.path, text: "hi", atSeconds: 0),
            caller: nil) else {
            Issue.record("a bundle was written with agent access off"); return
        }
        #expect(write.code == .consentRequired)
        // And nothing was written on the way to being refused.
        #expect(!FileManager.default.fileExists(atPath: recording.transcriptURL.path))
    }

    @MainActor
    @Test("An export's caption override is not written back to the bundle")
    func exportDoesNotWriteOverlayOverridesBackToTheBundle() async throws {
        // DISCRIMINATES AGAINST: applying the override by mutating the EDL and
        // saving it, which is what the editor's export sheet legitimately does
        // and what a copy-paste from it would do here. An export is not an
        // edit: asking for captions on one export must not turn captions on in
        // a person's document for ever, from a socket, with nothing on screen
        // to say it happened.
        //
        // The export itself fails on this fixture (there is no movie in it)
        // and that is fine: the claim is about `edit.json` afterwards, and the
        // override is applied before anything can throw.
        let recording = try bundle(captions: false)
        defer { try? FileManager.default.removeItem(at: recording.url) }

        _ = await host().handle(
            .export(bundlePath: recording.url.path, format: "mp4",
                    outputPath: FileManager.default.temporaryDirectory
                        .appending(path: "\(UUID().uuidString).mp4").path,
                    scale: 1, chapters: false, subtitles: false, maxSizeBytes: nil,
                    resolution: .source, clicks: false,
                    captions: true, markerBanners: true),
            caller: nil)

        let onDisk = try EditDecisionList.read(from: recording)
        #expect(onDisk.showSubtitles == false, "an export turned captions on in the document")
        #expect(onDisk.showMarkers == false, "an export turned marker banners on in the document")
    }
}
