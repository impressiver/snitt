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
    guard case .success(.export(let path, let format, let out, let scale, let chapters)) =
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
    guard case .success(.export(_, _, _, let scale, let chapters)) =
        CommandLineParser.parse(["export", "/tmp/x.snitt", "--format", "mp4",
                                 "--out", "/tmp/demo.mp4"])
    else { Issue.record("parse failed"); return }
    #expect(scale == 1.0)
    #expect(chapters == false)
}

@Test("export rejects a format this milestone cannot write")
func exportRejectsGif() {
    // gif is M3d. Accepting it here would produce an mp4 with a .gif name.
    #expect(CommandLineParser.parse(["export", "/tmp/x.snitt", "--format", "gif",
                                     "--out", "/tmp/demo.gif"]).isFailure)
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

private extension Result {
    var isFailure: Bool { if case .failure = self { return true }; return false }
}
