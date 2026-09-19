// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
@testable import SnittAutomation

@Test("targets list parses")
func parsesTargetsList() {
    #expect(CommandLineParser.parse(["targets", "list"]) == .success(.targetsList))
}

@Test("record start parses its target and audio flags")
func parsesRecordStart() {
    let parsed = CommandLineParser.parse(
        ["record", "start", "--app", "com.apple.Safari", "--mic", "--max-duration", "30"])
    guard case .success(.recordStart(let options)) = parsed else {
        Issue.record("expected recordStart, got \(parsed)"); return
    }
    #expect(options.bundleIdentifier == "com.apple.Safari")
    #expect(options.microphone == true)
    #expect(options.maxDurationSeconds == 30)
}

@Test("Microphone is OFF unless asked for")
func micDefaultsOff() {
    guard case .success(.recordStart(let options)) =
        CommandLineParser.parse(["record", "start", "--app", "com.apple.Safari"]) else {
        Issue.record("parse failed"); return
    }
    #expect(options.microphone == false,
            "an agent recording a demo should not capture the room by default")
}

@Test("record stop requires a session id")
func recordStopNeedsSession() {
    #expect(CommandLineParser.parse(["record", "stop"]).isFailure)
    #expect(CommandLineParser.parse(["record", "stop", "abc"]) == .success(.recordStop("abc")))
}

@Test("An unknown command fails with a message rather than defaulting to something")
func unknownCommandFails() {
    let parsed = CommandLineParser.parse(["frobnicate"])
    guard case .failure(let failure) = parsed else {
        Issue.record("an unknown command must not silently succeed"); return
    }
    #expect(failure.message.contains("frobnicate"))
}

@Test("record mark parses a session and an optional label")
func parsesRecordMark() {
    #expect(CommandLineParser.parse(["record", "mark", "abc"])
            == .success(.recordMark(sessionID: "abc", label: nil)))
    #expect(CommandLineParser.parse(["record", "mark", "abc", "--label", "ran tests"])
            == .success(.recordMark(sessionID: "abc", label: "ran tests")))
}

@Test("record mark without a session id is refused")
func recordMarkNeedsSession() {
    #expect(CommandLineParser.parse(["record", "mark"]).isFailure)
}

@Test("inspect parses a bundle path")
func parsesInspect() {
    #expect(CommandLineParser.parse(["inspect", "/tmp/x.snitt"])
            == .success(.inspect(bundlePath: "/tmp/x.snitt")))
}

@Test("inspect without a path is refused")
func inspectNeedsAPath() {
    #expect(CommandLineParser.parse(["inspect"]).isFailure)
}

@Test("trim parses a range")
func parsesTrimRange() {
    #expect(CommandLineParser.parse(["trim", "/tmp/x.snitt", "--start", "5", "--end", "25"])
            == .success(.trim(bundlePath: "/tmp/x.snitt", start: 5, end: 25, auto: false)))
}

@Test("trim --auto-trim parses without a range")
func parsesAutoTrim() {
    #expect(CommandLineParser.parse(["trim", "/tmp/x.snitt", "--auto-trim"])
            == .success(.trim(bundlePath: "/tmp/x.snitt", start: nil, end: nil, auto: true)))
}

@Test("trim with neither a range nor --auto-trim is refused")
func trimNeedsSomething() {
    // Writing an empty edit silently would look like it worked.
    #expect(CommandLineParser.parse(["trim", "/tmp/x.snitt"]).isFailure)
}

@Test("export parses its format, output and scale")
func parsesExport() {
    guard case .success(.export(let path, let format, let out, let scale, let chapters, _, _, _, _, _, _)) =
        CommandLineParser.parse(["export", "/tmp/x.snitt", "--format", "mp4",
                                 "--out", "/tmp/demo.mp4", "--scale", "0.5", "--chapters"])
    else { Issue.record("parse failed"); return }
    #expect(path == "/tmp/x.snitt")
    #expect(format == "mp4")
    #expect(out == "/tmp/demo.mp4")
    #expect(scale == 0.5)
    #expect(chapters == true)
}

@Test("export defaults to full scale and no chapters")
func exportDefaults() {
    guard case .success(.export(_, _, _, let scale, let chapters, _, let maxSizeBytes, _, _, _, _)) =
        CommandLineParser.parse(["export", "/tmp/x.snitt", "--format", "mp4",
                                 "--out", "/tmp/demo.mp4"])
    else { Issue.record("parse failed"); return }
    #expect(scale == 1.0)
    #expect(chapters == false)
    #expect(maxSizeBytes == nil)
}

@Test("export accepts gif")
func exportAcceptsGif() {
    let result = CommandLineParser.parse(
        ["export", "/tmp/b.snitt", "--format", "gif", "--out", "/tmp/o.gif"])
    guard case .success(.export(_, let format, _, _, _, _, _, _, _, _, _)) = result else {
        Issue.record("expected success, got \(result)"); return
    }
    #expect(format == "gif")
}

@Test("--max-size is parsed into bytes")
func maxSizeParsed() {
    let result = CommandLineParser.parse(
        ["export", "/tmp/b.snitt", "--format", "mp4", "--out", "/tmp/o.mp4",
         "--max-size", "10MB"])
    guard case .success(.export(_, _, _, _, _, _, let maxSize, _, _, _, _)) = result else {
        Issue.record("expected success, got \(result)"); return
    }
    // Asserts the VALUE reached the command, not merely that parsing
    // succeeded. A parser that accepts the flag and drops it passes a
    // success-only assertion.
    #expect(maxSize == 10_000_000)
}

@Test("A malformed --max-size is refused, not ignored")
func malformedMaxSizeRefused() {
    let result = CommandLineParser.parse(
        ["export", "/tmp/b.snitt", "--format", "mp4", "--out", "/tmp/o.mp4",
         "--max-size", "ten megabytes"])
    guard case .failure(let failure) = result else {
        Issue.record("expected failure, got \(result)"); return
    }
    #expect(failure.message.contains("--max-size"))
}

@Test("An unknown format is still refused")
func unknownFormatRefused() {
    // Opening the gif seam must not open it to everything.
    let result = CommandLineParser.parse(
        ["export", "/tmp/b.snitt", "--format", "webm", "--out", "/tmp/o.webm"])
    guard case .failure = result else {
        Issue.record("expected failure for webm"); return
    }
}

@Test("export rejects a zero or negative scale")
func exportRejectsNonPositiveScale() {
    // A degenerate scale would reach AVFoundation instead of being refused
    // where the person can still fix their command.
    #expect(CommandLineParser.parse(["export", "/tmp/x.snitt", "--format", "mp4",
                                     "--out", "/tmp/demo.mp4", "--scale", "0"]).isFailure)
    #expect(CommandLineParser.parse(["export", "/tmp/x.snitt", "--format", "mp4",
                                     "--out", "/tmp/demo.mp4", "--scale", "-0.5"]).isFailure)
}

@Test("trim rejects an end at or before start")
func trimRejectsInvertedRange() {
    #expect(CommandLineParser.parse(["trim", "/tmp/x.snitt", "--start", "9", "--end", "5"])
            .isFailure)
    #expect(CommandLineParser.parse(["trim", "/tmp/x.snitt", "--start", "5", "--end", "5"])
            .isFailure)
}

@Test("diagnostics export parses and carries the raw --out value")
func diagnosticsExportParses() {
    // Asserts the VALUE reached the command, not merely that parsing
    // succeeded — a parser that accepts `--out` and drops it (returning,
    // say, `.diagnosticsExport(outputPath: "")`) would pass a
    // success-only assertion. This is `main.swift`'s job to resolve, not
    // the parser's — see `requestBody(for:currentDirectory:)` and
    // `relativeOutIsResolved` in `Tests/SnittCLITests`.
    guard case .success(.diagnosticsExport(let outputPath)) =
        CommandLineParser.parse(["diagnostics", "export", "--out", "d.json"])
    else { Issue.record("parse failed"); return }
    #expect(outputPath == "d.json")
}

@Test("diagnostics export needs --out")
func diagnosticsExportNeedsOut() {
    #expect(CommandLineParser.parse(["diagnostics", "export"]).isFailure)
}

@Test("An unknown diagnostics subcommand is refused")
func diagnosticsUnknownSubcommandRefused() {
    #expect(CommandLineParser.parse(["diagnostics", "wipe"]).isFailure)
}

private extension Result {
    var isFailure: Bool { if case .failure = self { return true }; return false }
}

// MARK: - D107: captions, marker banners, and narration

@Test("Without a caption flag, the document's own setting stands")
func captionFlagsAreTriState() {
    // DISCRIMINATES AGAINST: `var captions = false`, the shape every other
    // boolean flag in this parser uses. It is right for `--chapters`, which
    // has nothing in the document to defer to, and wrong here: `showSubtitles`
    // lives in `edit.json` and a person may have turned it on in the editor.
    // A `false` default would take it away on every agent export.
    guard case .success(.export(_, _, _, _, _, _, _, _, _, let captions, let banners)) =
        CommandLineParser.parse(["export", "/tmp/x.snitt", "--format", "mp4",
                                 "--out", "/tmp/d.mp4"])
    else { Issue.record("parse failed"); return }
    #expect(captions == nil)
    #expect(banners == nil)
}

@Test("--captions and --no-captions say opposite things, and both are heard")
func captionFlagsCarryBothValues() {
    guard case .success(.export(_, _, _, _, _, _, _, _, _, let on, _)) =
        CommandLineParser.parse(["export", "/tmp/x.snitt", "--format", "mp4",
                                 "--out", "/tmp/d.mp4", "--captions"])
    else { Issue.record("parse failed"); return }
    #expect(on == true)

    guard case .success(.export(_, _, _, _, _, _, _, _, _, let off, let banners)) =
        CommandLineParser.parse(["export", "/tmp/x.snitt", "--format", "mp4",
                                 "--out", "/tmp/d.mp4", "--no-captions",
                                 "--marker-banners"])
    else { Issue.record("parse failed"); return }
    #expect(off == false)
    #expect(banners == true)
}

@Test("Contradicting yourself is refused, not resolved by argument order")
func contradictoryCaptionFlagsAreRefused() {
    // DISCRIMINATES AGAINST: last-one-wins, which a plain `case "--captions":
    // captions = true` loop gives for free. A caller who passed both does not
    // know what they asked for, and silently honouring whichever came last is
    // the confidently-wrong outcome §8 forbids.
    #expect(CommandLineParser.parse(
        ["export", "/tmp/x.snitt", "--format", "mp4", "--out", "/tmp/d.mp4",
         "--captions", "--no-captions"]).isFailure)
    #expect(CommandLineParser.parse(
        ["export", "/tmp/x.snitt", "--format", "mp4", "--out", "/tmp/d.mp4",
         "--marker-banners", "--no-marker-banners"]).isFailure)
    // Saying the same thing twice is not a contradiction.
    #expect(!CommandLineParser.parse(
        ["export", "/tmp/x.snitt", "--format", "mp4", "--out", "/tmp/d.mp4",
         "--captions", "--captions"]).isFailure)
}

@Test("narrate carries its line and its anchor")
func parsesNarrate() {
    guard case .success(.narrate(let path, let text, let at)) = CommandLineParser.parse(
        ["narrate", "/tmp/x.snitt", "--at", "4.5", "--text", "the tests are green"])
    else { Issue.record("parse failed"); return }
    #expect(path == "/tmp/x.snitt")
    #expect(text == "the tests are green")
    #expect(at == 4.5)
}

@Test("narrate refuses to default its anchor or its text")
func narrateNeedsBothFlags() {
    // DISCRIMINATES AGAINST: `var atSeconds = 0.0`. Zero is a real anchor, so
    // a default puts every forgotten line on the first frame and reports
    // success, and a missing `--text` would write an empty line.
    #expect(CommandLineParser.parse(["narrate", "/tmp/x.snitt", "--text", "hi"]).isFailure)
    #expect(CommandLineParser.parse(["narrate", "/tmp/x.snitt", "--at", "4"]).isFailure)
    #expect(CommandLineParser.parse(
        ["narrate", "/tmp/x.snitt", "--at", "4", "--text", "  "]).isFailure)
    // "inf" parses as a Double and is not a time.
    #expect(CommandLineParser.parse(
        ["narrate", "/tmp/x.snitt", "--at", "inf", "--text", "hi"]).isFailure)
    #expect(CommandLineParser.parse(
        ["narrate", "/tmp/x.snitt", "--at", "-1", "--text", "hi"]).isFailure)
}

@Test("transcript takes a bundle path and nothing else")
func parsesTranscript() {
    guard case .success(.transcript(let path)) =
        CommandLineParser.parse(["transcript", "/tmp/x.snitt"])
    else { Issue.record("parse failed"); return }
    #expect(path == "/tmp/x.snitt")
    // A trailing flag is refused rather than ignored: silently dropping an
    // option a caller passed is how they learn it worked when it did not.
    #expect(CommandLineParser.parse(["transcript", "/tmp/x.snitt", "--lines"]).isFailure)
    #expect(CommandLineParser.parse(["transcript"]).isFailure)
}
