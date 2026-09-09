// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittExport
@testable import SnittDocument

/// Marker transcripts as subtitles (D50).
///
/// The distinction from `WebVTTChapters` is the whole point and is what most of
/// these assert. A chapter spans to the next marker, which is right for
/// navigation and catastrophic for a caption: it would leave a sentence on
/// screen for as long as it takes to reach the next marker, which can be
/// minutes.
@Suite
struct WebVTTSubtitlesTests {
    private func marker(_ time: Double, transcript: String?, label: String? = nil) -> LoggedEvent {
        LoggedEvent(timeSeconds: time, kind: .marker, label: label, transcript: transcript)
    }

    @Test("A cue lasts reading time, NOT until the next marker")
    func cueEndsAfterReadingTime() throws {
        // Two markers 60s apart. A chapter renderer gives the first a 60s span.
        let cues = WebVTTSubtitles.cues(
            markers: [marker(0, transcript: "Here is the settings window"),
                      marker(60, transcript: "And here is the result")],
            duration: 120)
        let first = try #require(cues.first)
        #expect(first.end - first.start < 10,
                "cue ran \(first.end - first.start)s — it is spanning to the next marker")
    }

    @Test("Longer text gets more time")
    func longerTextReadsLonger() throws {
        let short = try #require(WebVTTSubtitles.cues(
            markers: [marker(0, transcript: "Saved.")], duration: 60).first)
        let long = try #require(WebVTTSubtitles.cues(
            markers: [marker(0, transcript: String(repeating: "word ", count: 20))],
            duration: 60).first)
        #expect(long.end - long.start > short.end - short.start,
                "cue duration ignores how much there is to read")
    }

    @Test("Cues never overlap, even when markers are close together")
    func cuesDoNotOverlap() {
        // Two captions on screen at once is a rendering bug in every player.
        // A pure reading-time calculation with no clamp produces exactly that
        // whenever someone narrates two things a second apart.
        let cues = WebVTTSubtitles.cues(
            markers: [marker(0, transcript: String(repeating: "word ", count: 20)),
                      marker(1, transcript: "next")],
            duration: 60)
        #expect(cues.count == 2)
        #expect(cues[0].end <= cues[1].start + 0.001,
                "cue 1 ends at \(cues[0].end) but cue 2 starts at \(cues[1].start)")
    }

    @Test("A marker with only a label produces no subtitle")
    func labelOnlyMarkersAreNotSubtitles() {
        // A marker labelled "opened settings" is a chapter, not something
        // anyone said. Rendering labels as captions would put UI notes into the
        // subtitle track — and every recording has those, because pause,
        // resume and screenshot all drop labelled markers.
        let cues = WebVTTSubtitles.cues(
            markers: [marker(1, transcript: nil, label: "Paused"),
                      marker(2, transcript: "  ", label: "Screenshot")],
            duration: 60)
        #expect(cues.isEmpty)
    }

    @Test("Non-marker events are ignored")
    func onlyMarkers() {
        let cues = WebVTTSubtitles.cues(
            markers: [LoggedEvent(timeSeconds: 1, kind: .click, transcript: "not speech")],
            duration: 60)
        #expect(cues.isEmpty)
    }

    @Test("A cue past the end of the export is dropped, not clamped to zero length")
    func markersBeyondDurationAreDropped() {
        let cues = WebVTTSubtitles.cues(
            markers: [marker(90, transcript: "after the end")], duration: 60)
        #expect(cues.isEmpty)
    }

    @Test("The rendered file is valid WebVTT with the transcript as the text")
    func rendersValidWebVTT() {
        let vtt = WebVTTSubtitles.render(
            markers: [marker(1.5, transcript: "Clicking save writes it to disk")],
            duration: 60)
        #expect(vtt.hasPrefix("WEBVTT\n"))
        #expect(vtt.contains("00:00:01.500 --> "))
        #expect(vtt.contains("Clicking save writes it to disk"))
    }

    @Test("No transcripts at all is still a valid file")
    func emptyIsValid() {
        #expect(WebVTTSubtitles.render(markers: [], duration: 60) == "WEBVTT\n")
    }
}

/// Subtitles reach the exported sidecar, on the EXPORT clock.
///
/// The join that can be wrong invisibly: markers live in bundle time and the
/// export is trimmed, so a cue written from raw marker times lands wherever the
/// cuts left it. `MarkerMapping` is what converts, and this asserts the export
/// path actually uses it for subtitles as it does for chapters.
@Suite
struct SubtitleExportTests {
    @Test("--subtitles writes a separate file, on export time, from transcripts only")
    func exportWritesSubtitles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "subs-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 10.0)
        try EventLog(events: [
            // AFTER the cut, so it survives into the export — a marker at 1s
            // would be inside the cut and legitimately dropped, which would
            // make this assert nothing.
            LoggedEvent(timeSeconds: 4, kind: .marker, label: "Paused"),
            LoggedEvent(timeSeconds: 6, kind: .marker, label: "step two",
                        transcript: "And this is the result"),
        ]).write(to: bundle)
        // Cut 0-3s, so source 6s becomes export 3s.
        try EditDecisionList(cuts: [Cut(range: TimeRange(start: 0, end: 3))]).write(to: bundle)

        let out = FileManager.default.temporaryDirectory
            .appending(path: "subs-\(UUID().uuidString).mp4")
        let chapters = out.deletingPathExtension().appendingPathExtension("vtt")
        let subtitles = out.deletingPathExtension().appendingPathExtension("subtitles.vtt")
        defer { for u in [out, chapters, subtitles] { try? FileManager.default.removeItem(at: u) } }

        _ = try await MovieExporter.export(
            bundle: bundle, edl: try EditDecisionList.read(from: bundle), scale: 1.0,
            to: out, chaptersURL: chapters, subtitlesURL: subtitles, format: "mp4")

        let text = try String(contentsOf: subtitles, encoding: .utf8)
        #expect(text.contains("And this is the result"))
        // The label-only marker must not appear: every recording has those now,
        // because pause, resume and screenshot all drop labelled markers.
        #expect(!text.contains("Paused"), "a label-only marker became a caption")
        // Export time, not bundle time: 6s source minus the 3s cut.
        #expect(text.contains("00:00:03."), "cue is on bundle time, not export time:\n\(text)")

        // A separate file from chapters, which must still carry the labels.
        let chapterText = try String(contentsOf: chapters, encoding: .utf8)
        #expect(chapterText.contains("Paused"))
    }
}
