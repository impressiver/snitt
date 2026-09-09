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
    guard case .success(.export(let path, let format, let out, let scale, let chapters, _, _, _, _)) =
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
    guard case .success(.export(_, _, _, let scale, let chapters, _, let maxSizeBytes, _, _)) =
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
    guard case .success(.export(_, let format, _, _, _, _, _, _, _)) = result else {
        Issue.record("expected success, got \(result)"); return
    }
    #expect(format == "gif")
}

@Test("--max-size is parsed into bytes")
func maxSizeParsed() {
    let result = CommandLineParser.parse(
        ["export", "/tmp/b.snitt", "--format", "mp4", "--out", "/tmp/o.mp4",
         "--max-size", "10MB"])
    guard case .success(.export(_, _, _, _, _, _, let maxSize, _, _)) = result else {
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
