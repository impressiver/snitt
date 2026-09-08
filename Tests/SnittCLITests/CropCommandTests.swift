import Testing
import Foundation
@testable import snitt_cli
@testable import SnittAutomation
@testable import SnittDocument

/// `snitt crop` — the CLI half of a feature that shipped GUI-only.
///
/// §4.8 and §6 hold that the CLI and the GUI are one model, not two. Crop
/// landed in the editor and the EDL first, which left the CLI able to READ a
/// crop (every export honours it) but never to set one — the same asymmetry
/// D60 found when `snitt trim` could destroy cuts it could not make.
@Suite
struct CropCommandTests {
    private func parse(_ args: [String]) -> Result<ParsedCommand, ParseFailure> {
        CommandLineParser.parse(args)
    }

    @Test("A full rect parses into a crop command")
    func fullRectParses() throws {
        let result = parse(["crop", "/tmp/a.snitt", "--x", "0.25", "--y", "0.1",
                            "--width", "0.5", "--height", "0.8"])
        guard case .success(.crop(let path, let rect)) = result else {
            Issue.record("did not parse as crop: \(result)"); return
        }
        #expect(path == "/tmp/a.snitt")
        let crop = try #require(rect)
        #expect(abs(crop.x - 0.25) < 1e-9)
        #expect(abs(crop.height - 0.8) < 1e-9)
    }

    @Test("--reset parses as removing the crop, not as cropping to nothing")
    func resetParses() {
        guard case .success(.crop(_, let rect)) = parse(["crop", "/tmp/a.snitt", "--reset"]) else {
            Issue.record("--reset did not parse"); return
        }
        // nil, not CropRect(0,0,0,0) — the latter renders a frame with no
        // picture in it.
        #expect(rect == nil)
    }

    @Test("A partial rect is refused rather than defaulted")
    func partialRectIsRefused() {
        // Deliberately omits x and y while giving a VALID width and height, so
        // the separate "size must be > 0" guard cannot be what rejects it. A
        // first version passed `--x 0.5` alone; defaulting the missing values
        // to zero then produced a zero-size rect that the size guard caught,
        // so the test passed against an implementation that defaults instead of
        // refusing — the wrong reason, and invisible because both messages
        // mention --width.
        guard case .failure(let failure) = parse(
            ["crop", "/tmp/a.snitt", "--width", "0.5", "--height", "0.5"]) else {
            Issue.record("a rect missing --x/--y was accepted"); return
        }
        #expect(failure.message.contains("--x"))
    }

    @Test("--reset cannot be combined with a rect")
    func resetWithRectIsRefused() {
        guard case .failure = parse(["crop", "/tmp/a.snitt", "--reset", "--x", "0.5",
                                     "--y", "0", "--width", "0.5", "--height", "1"]) else {
            Issue.record("contradictory flags accepted"); return
        }
    }

    @Test("A zero-size crop is refused")
    func zeroSizeIsRefused() {
        guard case .failure = parse(["crop", "/tmp/a.snitt", "--x", "0", "--y", "0",
                                     "--width", "0", "--height", "1"]) else {
            Issue.record("a zero-width crop was accepted — that renders no picture"); return
        }
    }

    @Test("A relative path is resolved before it reaches the wire")
    func relativePathIsResolved() {
        // Calls the CLI's OWN requestBody, not a copy of it. A first version of
        // this test rebuilt the body inside the test and therefore asserted
        // that the test's own helper resolved paths — which is true by
        // construction and says nothing about the CLI.
        //
        // The app's working directory is "/" and cannot know what a relative
        // path meant (M3c finding #3), so resolution must happen client-side.
        guard case .success(let command) = parse(["crop", "demo.snitt", "--reset"]) else {
            Issue.record("did not parse"); return
        }
        guard case .crop(let path, _) = requestBody(for: command, currentDirectory: "/tmp/work") else {
            Issue.record("wrong body"); return
        }
        #expect(path == "/tmp/work/demo.snitt", "path was not resolved: \(path)")
    }
}

/// `snitt record pause|resume` parsing (M5e, D53).
@Suite
struct RecordPauseCommandTests {
    @Test("pause and resume parse with a session id")
    func parses() {
        guard case .success(.recordPause(let session)) =
                CommandLineParser.parse(["record", "pause", "S1"]) else {
            Issue.record("`record pause` did not parse"); return
        }
        #expect(session == "S1")
        guard case .success(.recordResume("S1")) =
                CommandLineParser.parse(["record", "resume", "S1"]) else {
            Issue.record("`record resume` did not parse"); return
        }
    }

    @Test("A missing session id is refused, not defaulted to the current one")
    func missingSessionIsRefused() {
        // Defaulting would let an agent pause a recording it does not own by
        // omitting an argument — the ownership check exists precisely to stop
        // that, and it cannot run without an id to check.
        guard case .failure = CommandLineParser.parse(["record", "pause"]) else {
            Issue.record("a missing session id was accepted"); return
        }
    }
}
