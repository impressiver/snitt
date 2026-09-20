// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
import SnittAutomation
import SnittCapture
import SnittDocument
@testable import SnittApp

/// One writer for a recording (W4).
///
/// `EditorWindowController.applyAndSave` takes `self.edl` and writes it WHOLE.
/// It does not re-read, and nothing in `SnittApp` watches the bundle — no
/// `DispatchSource`, no `NSFilePresenter`. So an agent that wrote `edit.json`
/// under an open window had its work destroyed by that window's next save,
/// with no error and no trace.
///
/// This is D60's failure class in the other direction. D60 fixed `snitt trim`
/// deleting the GUI's cuts because "§4.8 and §6 hold that the CLI and GUI are
/// one model, not two; a CLI that silently deletes the GUI's edits is two."
/// The GUI deleting the CLI's edits is the same two models.
///
/// The fix is to REFUSE (W4, product owner). These tests are therefore mostly
/// about what a refusal must be: before the write, with its own code, and
/// without an alert.
@Suite("One writer for a recording")
struct OneWriterForARecordingTests {

    /// A bundle on disk with the sidecars these verbs read, and no capture.
    private func bundle() throws -> SnittBundle {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "one-writer-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        try RecordingMetadata(createdAt: Date(), initiator: .agent).write(to: bundle)
        try EventLog(events: []).write(to: bundle)
        try EditDecisionList.fullRange().write(to: bundle)
        return bundle
    }

    /// `open` decides what the injected probe answers.
    ///
    /// The production probe needs a real `NSWindow` on the main actor, so a
    /// test that could not substitute it would only ever exercise the
    /// nothing-is-open branch — the branch that already worked.
    private func host(open: Bool) -> AutomationHost {
        AutomationHost(coordinator: FakeCoordinator(),
                       settings: { AgentSettings(agentRecordingEnabled: true) },
                       onRecordingState: { _ in },
                       isOpenInEditor: { _ in open },
                       auditLogURL: FileManager.default.temporaryDirectory
                           .appending(path: "one-writer-audit-\(UUID().uuidString).jsonl"))
    }

    /// Every verb that CHANGES a recording, so a fifth one added later is
    /// caught by the sweep below rather than by a lost edit.
    private func mutatingRequests(for path: String) -> [(String, AutomationRequest.Body)] {
        [
            ("crop", .crop(bundlePath: path, rect: CropRect(x: 0, y: 0, width: 0.5, height: 0.5))),
            ("trim", .trim(bundlePath: path, start: 1, end: 2, auto: false)),
            ("auto-deep-trim", .autoDeepTrim(bundlePath: path, criteria: .preset(.default))),
            ("narrate", .addNarration(bundlePath: path, text: "hello", atSeconds: 0)),
        ]
    }

    @MainActor
    @Test("An agent edit to an open document is refused, not silently lost")
    func anOpenDocumentRefusesEveryMutatingVerb() async throws {
        // WRONG IMPLEMENTATION: today's code, which writes `edit.json` and
        // returns success. Every existing assertion still passes — the file on
        // disk really does say what the agent asked for, right up until the
        // open window's next save takes `self.edl` and overwrites it. Verified
        // to fail by removing the guard: all four verbs return success.
        //
        // Also fails against guarding only `trim`, which is the verb the bug
        // was noticed through. `crop`, `auto-deep-trim` and `narrate` write
        // the same two sidecars the editor saves.
        let recording = try bundle()
        defer { try? FileManager.default.removeItem(at: recording.url) }
        let subject = host(open: true)

        for (verb, request) in mutatingRequests(for: recording.url.path) {
            let response = await subject.handle(request, caller: nil)
            guard case .failure(let error) = response else {
                Issue.record("\(verb) should have been refused, got \(response)"); continue
            }
            #expect(error.code == .bundleOpenInEditor, "\(verb) used the wrong code")
            #expect(error.message.contains(recording.url.lastPathComponent),
                    "\(verb)'s refusal must name the bundle, so an agent driving several knows which")
        }
    }

    @MainActor
    @Test("A refused edit leaves the document byte-identical")
    func refusalWritesNothing() async throws {
        // WRONG IMPLEMENTATION: checking AFTER the write and reporting the
        // conflict — which reads like a fix, passes the test above, and has
        // already destroyed the data the check exists to protect (W6).
        // Verified to fail by moving the guard below `edl.write(to: bundle)`.
        let recording = try bundle()
        defer { try? FileManager.default.removeItem(at: recording.url) }
        let before = try Data(contentsOf: recording.editURL)

        for (verb, request) in mutatingRequests(for: recording.url.path) {
            _ = await host(open: true).handle(request, caller: nil)
            let after = try Data(contentsOf: recording.editURL)
            #expect(after == before, "\(verb) wrote to edit.json before refusing")
            #expect(!FileManager.default.fileExists(atPath: recording.transcriptURL.path),
                    "\(verb) wrote a transcript before refusing")
        }
    }

    @MainActor
    @Test("An agent edit to a CLOSED document still writes the file")
    func aClosedDocumentIsUntouched() async throws {
        // THE CONTROL, and the reason it is not optional: a change that
        // refused everything would pass both tests above and break every
        // headless use of Snitt, which is most of them. Verified to fail by
        // making the guard unconditional.
        let recording = try bundle()
        defer { try? FileManager.default.removeItem(at: recording.url) }

        // `narrate` rather than `crop`, because this fixture has no
        // `capture.mov`: crop writes `edit.json` and THEN reads the movie for
        // the pixel dimensions it reports, so it fails here for a reason that
        // has nothing to do with the guard. Narration touches only sidecars.
        let response = await host(open: false).handle(
            .addNarration(bundlePath: recording.url.path, text: "hello", atSeconds: 0),
            caller: nil)
        guard case .narrationAdded = response else {
            Issue.record("a closed document must still take narration, got \(response)"); return
        }
        let transcript = try Transcript.read(from: recording)
        #expect(transcript.words.count == 1, "the narration did not reach transcript.json")

        // And the document path, through a verb that writes `edit.json`. The
        // response is ignored deliberately: what is under test is that the
        // write HAPPENED, not what crop could report about a bundle with no
        // movie in it.
        _ = await host(open: false).handle(
            .crop(bundlePath: recording.url.path,
                  rect: CropRect(x: 0, y: 0, width: 0.5, height: 0.5)),
            caller: nil)
        let written = try EditDecisionList.read(from: recording)
        #expect(written.crop != nil, "the crop did not reach edit.json")
    }

    @MainActor
    @Test("Reading a recording open in the editor is still allowed")
    func readOnlyVerbsAreNotRefused() async throws {
        // WRONG IMPLEMENTATION: guarding on bundle path at the dispatcher, so
        // an open window makes the recording unreachable rather than
        // uneditable. It reads as the safer choice and is strictly worse: an
        // agent watching a person edit can no longer inspect what they have,
        // and `inspect` is what stops an agent narrating a recording it has
        // never seen. Verified to fail by moving the guard into `handle`.
        let recording = try bundle()
        defer { try? FileManager.default.removeItem(at: recording.url) }
        let subject = host(open: true)

        guard case .inspected = await subject.handle(
            .inspect(bundlePath: recording.url.path), caller: nil) else {
            Issue.record("inspect must not be refused for an open document"); return
        }
        guard case .transcriptRead = await subject.handle(
            .transcript(bundlePath: recording.url.path), caller: nil) else {
            Issue.record("transcript must not be refused for an open document"); return
        }
    }

    @Test("The refusal is its own answer, and exits differently from internal_error")
    func theCodeIsDistinct() {
        // WRONG IMPLEMENTATION: reusing `internal_error` "so nothing breaks",
        // or `busy`, whose contract is "nothing is wrong, retry shortly". This
        // is the one failure an agent must NOT spin on: it clears when a
        // PERSON closes the window. Verified to fail by mapping it to 16.
        let exit = AutomationError.exitCode[.bundleOpenInEditor]
        #expect(exit != nil, "a code with no exit code exits 1, like everything else")
        #expect(exit != AutomationError.exitCode[.internalError])
        #expect(exit != AutomationError.exitCode[.busy])
        #expect(exit != AutomationError.exitCode[.invalidArguments])
        #expect(exit != AutomationError.exitCode[.unusableRecording])

        // The codes that shipped keep the numbers they shipped: §15 makes
        // these a public interface, so a new code appends rather than
        // renumbering.
        #expect(AutomationError.exitCode[.internalError] == 16)
    }

    @Test("A client that has never heard of this code still reads the response")
    func anOlderClientDegradesRatherThanFailing() throws {
        // WRONG IMPLEMENTATION: the SYNTHESIZED `RawRepresentable` decoding.
        // It throws `dataCorrupted` on an unknown string, so an older `snitt`
        // binary receiving this brand-new code would fail the WHOLE response
        // and report "Snitt and snitt-mcp are out of sync" instead of the
        // refusal. D106's lenient decoder is what makes adding this case safe,
        // and this test is what keeps that true. Verified to fail by deleting
        // the custom `init(from:)`.
        let json = #"{"code":"a_code_from_a_later_snitt","message":"x"}"#
        let decoded = try JSONDecoder().decode(
            AutomationError.self, from: Data(json.utf8))
        #expect(decoded.code == .internalError)

        // And this build's own code round-trips as itself.
        let mine = AutomationError(code: .bundleOpenInEditor, message: "x")
        let round = try JSONDecoder().decode(
            AutomationError.self, from: JSONEncoder().encode(mine))
        #expect(round.code == .bundleOpenInEditor)
    }
}
