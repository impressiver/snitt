// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
@testable import SnittApp
@testable import SnittExport
@testable import SnittDocument

/// "Export for" as a picker in the export sheet rather than a menu command.
///
/// Three rules, and each is a test here: choosing a preset SETS the settings,
/// choosing one does NOT export, and changing anything by hand falls back to
/// Custom.
///
/// The last one is the interesting one. `destinationPreset` is DERIVED from the
/// settings rather than stored beside them, so "manual edit means Custom" is a
/// fact about the request rather than a rule some control has to remember to
/// apply. A stored flag would need clearing by every control that can change a
/// setting, and the first one added later without that line would leave the
/// menu claiming a preset the settings no longer match.
@Suite(.serialized)
@MainActor
struct ExportPresetSelectionTests {
    init() { _ = NSApplication.shared }

    private let base = URL(fileURLWithPath: "/tmp/demo.mp4")

    private func request() -> ExportRequest { ExportRequest(destination: base) }

    @Test("A fresh request is Custom")
    func freshRequestIsCustom() {
        #expect(request().destinationPreset == nil)
    }

    @Test("Choosing a preset adopts its format, resolution and ceiling")
    func presetSetsTheSettings() throws {
        var r = request()
        let github = try #require(ExportDestination.named("github"))
        r.apply(github)

        #expect(r.resolution == github.resolution)
        #expect(r.format == github.format)
        #expect(r.maxSizeBytes == github.maxSizeBytes)
        // And it reads back as that preset, which is what keeps the picker
        // showing the thing that was chosen.
        #expect(r.destinationPreset == github)
    }

    @Test("Choosing a preset leaves the overlays and the folder alone")
    func presetDoesNotTouchUnrelatedSettings() throws {
        // A preset says what a place will ACCEPT. It has no opinion about
        // whether you wanted captions burned in, and overriding them would
        // make choosing one undo a decision it knows nothing about.
        var r = ExportRequest(destination: URL(fileURLWithPath: "/elsewhere/demo.mp4"),
                              drawClicks: true, drawSubtitles: true, drawMarkers: true)
        r.apply(try #require(ExportDestination.named("slack")))

        #expect(r.drawClicks && r.drawSubtitles && r.drawMarkers)
        #expect(r.destination.deletingLastPathComponent().path == "/elsewhere")
    }

    @Test("Changing the resolution by hand falls back to Custom")
    func manualResolutionIsCustom() throws {
        // The requirement, stated directly. Also the reason the ceiling has to
        // go with it: a size budget left behind would make the size ladder
        // walk back down from the resolution just chosen, so the setting would
        // not stick and nothing would say why.
        var r = request()
        r.apply(try #require(ExportDestination.named("github")))
        #expect(r.destinationPreset != nil)

        r.resolution = .hd1080p
        r.clearPreset()

        #expect(r.destinationPreset == nil)
        #expect(r.maxSizeBytes == nil, "a manual resolution kept the preset's byte budget")
        #expect(r.resolution == .hd1080p, "falling back to Custom undid the choice that caused it")
    }

    @Test("Changing the format by hand falls back to Custom")
    func manualFormatIsCustom() throws {
        var r = request()
        r.apply(try #require(ExportDestination.named("github")))

        r.setFormat("gif")
        r.clearPreset()

        #expect(r.destinationPreset == nil)
        #expect(r.format == "gif")
    }

    @Test("Trying three presets does not stack three suffixes on the filename")
    func filenameDoesNotAccumulateSuffixes() throws {
        // `demo-github-slack-x.mp4` is worse than no suffix at all: the
        // filename is the only thing telling two exports of one recording
        // apart once they are in a folder together, and one naming the wrong
        // preset is actively misleading.
        var r = request()
        for id in ["github", "slack", "x"] {
            r.apply(try #require(ExportDestination.named(id)))
        }
        #expect(r.destination.deletingPathExtension().lastPathComponent == "demo-x")

        // And Custom takes the suffix back off rather than leaving the last
        // preset's name on a file that is no longer for that place.
        r.clearPreset()
        #expect(r.destination.deletingPathExtension().lastPathComponent == "demo")
    }

    @Test("No two presets are indistinguishable")
    func presetsAreUniquelyIdentifiable() {
        // `destinationPreset` matches on format, resolution and ceiling. Two
        // presets agreeing on all three would make the picker show whichever
        // came first in the list, so choosing one would silently display the
        // other. Several DO share a format and resolution — five are mp4 at
        // 1080p — and only the ceiling separates them.
        let keys = ExportDestination.all.map { "\($0.format)|\($0.resolution.rawValue)|\($0.maxSizeBytes)" }
        #expect(Set(keys).count == keys.count,
                "two presets are indistinguishable to the picker: \(keys)")
    }

    @Test("A recording longer than the preset allows is flagged BEFORE exporting")
    func durationWarningAppearsInTheSheet() throws {
        // It used to be an alert AFTER the export, because `File ▸ Export for`
        // wrote the file before there was anywhere to say it. Knowing while
        // you are still choosing is the point of moving into the sheet.
        let x = try #require(ExportDestination.named("x"))
        let limit = try #require(x.maxDurationSeconds)

        let over = ExportSheet.durationWarning(for: x, durationSeconds: limit + 10)
        let text = try #require(over, "no warning for a recording past the limit")
        #expect(text.contains(x.name))
        // Says it exports anyway. Snitt does not shorten a recording to satisfy
        // someone else's policy — the person would find out by watching their
        // own demo stop mid-sentence.
        #expect(text.lowercased().contains("full length"))

        #expect(ExportSheet.durationWarning(for: x, durationSeconds: limit - 10) == nil)
    }

    @Test("No preset, or no known duration, means no warning")
    func noWarningWithoutBothFacts() throws {
        #expect(ExportSheet.durationWarning(for: nil, durationSeconds: 100_000) == nil)
        // Zero is "the caller does not know", not "shorter than every limit".
        // Warning there would fire on every sheet that opens before the
        // composition has been measured.
        let x = try #require(ExportDestination.named("x"))
        #expect(ExportSheet.durationWarning(for: x, durationSeconds: 0) == nil)
        // And a preset with no duration limit never warns, however long it is.
        let github = try #require(ExportDestination.named("github"))
        #expect(github.maxDurationSeconds == nil)
        #expect(ExportSheet.durationWarning(for: github, durationSeconds: 100_000) == nil)
    }
}
