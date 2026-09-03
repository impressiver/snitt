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

private extension Result {
    var isFailure: Bool { if case .failure = self { return true }; return false }
}
