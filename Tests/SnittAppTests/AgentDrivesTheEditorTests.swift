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

/// An agent drives Snitt's own editor (D109).
///
/// The verbs cover VIEW STATE only — a playhead position and a selection —
/// because that is the part which is not in the document and which no existing
/// verb can reach. Everything that changes the recording already has a verb
/// and simply becomes visible once the document is open, which is true because
/// of W7's routing.
@Suite("An agent drives the editor")
struct AgentDrivesTheEditorTests {

    private func bundle(initiator: Initiator) throws -> SnittBundle {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "drives-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        try RecordingMetadata(createdAt: Date(), initiator: initiator).write(to: bundle)
        try EventLog(events: []).write(to: bundle)
        try EditDecisionList.fullRange().write(to: bundle)
        return bundle
    }

    private func host() -> AutomationHost {
        AutomationHost(coordinator: FakeCoordinator(),
                       settings: { AgentSettings(agentRecordingEnabled: true) },
                       onRecordingState: { _ in },
                       auditLogURL: FileManager.default.temporaryDirectory
                           .appending(path: "drives-audit-\(UUID().uuidString).jsonl"))
    }

    // MARK: Who may put a recording on screen (E11)

    @MainActor
    @Test("An agent may not open a recording a person made")
    func openRefusesAHumanRecording() async throws {
        // WRONG IMPLEMENTATION: opening any readable bundle. `editor open` is
        // the one verb here that is NOT bounded by what the agent could
        // already reach — it puts a recording ON SCREEN, so a prompt-injected
        // agent could display a recording its owner never meant shown, while
        // they are screen-sharing or being watched.
        //
        // `screenshotForAgent` sets the precedent and lands the same way: "a
        // screenshot of someone else's screen is the most obviously sensitive
        // thing this surface could hand out, and §5's posture makes that
        // Snitt's problem rather than the caller's." Verified to fail by
        // dropping the initiator check.
        let recording = try bundle(initiator: .human)
        defer { try? FileManager.default.removeItem(at: recording.url) }

        let response = await host().handle(
            .editorOpen(bundlePath: recording.url.path), caller: nil)
        guard case .failure(let error) = response else {
            Issue.record("a human recording must not open, got \(response)"); return
        }
        #expect(error.code == .consentRequired)
        #expect(error.hint?.contains("recording it made") == true,
                "the refusal must say what the rule IS, not just that it refused")
    }

    @MainActor
    @Test("A bundle whose maker cannot be determined is refused, not opened")
    func openRefusesUnreadableMetadata() async throws {
        // WRONG IMPLEMENTATION: `(try? RecordingMetadata.read(from:))?.initiator
        // == .agent` collapses to false and refuses — which is right — but the
        // NEAR miss is `?? .agent`, or reading the initiator with a default.
        // This repo has the absent-versus-unreadable distinction at four other
        // sidecar call sites, and it matters more here than anywhere: "I could
        // not tell who made this" must never resolve to "show it".
        let recording = try bundle(initiator: .agent)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        try Data("not json".utf8).write(to: recording.url.appending(path: "meta.json"))

        let response = await host().handle(
            .editorOpen(bundlePath: recording.url.path), caller: nil)
        guard case .failure(let error) = response else {
            Issue.record("unreadable metadata must refuse, got \(response)"); return
        }
        #expect(error.code == .unusableRecording)
    }

    @MainActor
    @Test("Agent access being off refuses every editor verb, not just open")
    func everyVerbIsGated() async throws {
        // WRONG IMPLEMENTATION: gating `open` (which obviously discloses) and
        // leaving play, pause, seek and select ungated because they "only move
        // a playhead". They move a playhead in a window a person is looking
        // at, and §5.3's switch is the kill switch for the whole agent
        // surface, not for its most obvious half.
        let recording = try bundle(initiator: .agent)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        let off = AutomationHost(
            coordinator: FakeCoordinator(),
            settings: { AgentSettings(agentRecordingEnabled: false) },
            onRecordingState: { _ in },
            auditLogURL: FileManager.default.temporaryDirectory
                .appending(path: "drives-audit-\(UUID().uuidString).jsonl"))

        let verbs: [(String, AutomationRequest.Body)] = [
            ("open", .editorOpen(bundlePath: recording.url.path)),
            ("play", .editorPlay(bundlePath: recording.url.path)),
            ("pause", .editorPause(bundlePath: recording.url.path)),
            ("seek", .editorSeek(bundlePath: recording.url.path, toSeconds: 1)),
            ("select", .editorSelect(bundlePath: recording.url.path,
                                     fromSeconds: 1, toSeconds: 2)),
        ]
        for (name, request) in verbs {
            guard case .failure(let error) = await off.handle(request, caller: nil) else {
                Issue.record("\(name) ran with agent access off"); continue
            }
            #expect(error.code == .consentRequired, "\(name) used the wrong code")
        }
    }

    // MARK: A closed document is not a silent no-op

    @MainActor
    @Test("Driving a recording that is not open fails, rather than doing nothing")
    func aClosedDocumentIsNotASilentNoOp() async throws {
        // WRONG IMPLEMENTATION: returning success when no window is open,
        // because "there was nothing to do". An agent cannot watch the window,
        // so a cheerful success would be indistinguishable from a seek that
        // worked — §8's confidently-wrong outcome, and the one this whole
        // surface exists to avoid. The remedy is a DIFFERENT call, which a
        // hint can name and a no-op cannot.
        let recording = try bundle(initiator: .agent)
        defer { try? FileManager.default.removeItem(at: recording.url) }

        let response = await host().handle(
            .editorSeek(bundlePath: recording.url.path, toSeconds: 2), caller: nil)
        guard case .failure(let error) = response else {
            Issue.record("seeking a closed document must fail, got \(response)"); return
        }
        #expect(error.code == .targetNotFound)
        #expect(error.hint?.contains("editor open") == true,
                "the hint must name the call that fixes it")
    }

    // MARK: Arguments

    @MainActor
    @Test("Half a selection is refused, not completed by guessing")
    func halfASelectionIsRefused() async throws {
        // WRONG IMPLEMENTATION: defaulting the missing end to 0 or to the
        // recording's duration. That is a DIFFERENT selection from the one
        // asked for, applied silently, and the agent has no way to see that it
        // got one. Refusing costs it one round trip and tells it exactly what
        // to send.
        let recording = try bundle(initiator: .agent)
        defer { try? FileManager.default.removeItem(at: recording.url) }

        guard case .failure(let error) = await host().handle(
            .editorSelect(bundlePath: recording.url.path, fromSeconds: 3, toSeconds: nil),
            caller: nil) else {
            Issue.record("half a selection must be refused"); return
        }
        #expect(error.code == .invalidArguments)
    }

    @MainActor
    @Test("A backwards or non-finite selection is refused")
    func anInvertedSelectionIsRefused() async throws {
        // WRONG IMPLEMENTATION: `TimeRange(start:end:)` with no check, which
        // yields a range whose end precedes its start. Nothing downstream
        // rejects it, so the highlight is drawn empty and the agent is told it
        // selected something.
        let recording = try bundle(initiator: .agent)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        let subject = host()

        for (name, from, to) in [("backwards", 5.0, 2.0),
                                 ("equal", 2.0, 2.0),
                                 ("infinite", 0.0, Double.infinity)] {
            guard case .failure(let error) = await subject.handle(
                .editorSelect(bundlePath: recording.url.path,
                              fromSeconds: from, toSeconds: to),
                caller: nil) else {
                Issue.record("\(name) selection was accepted"); continue
            }
            #expect(error.code == .invalidArguments, "\(name) used the wrong code")
        }
    }

    @MainActor
    @Test("A negative or non-finite seek is refused")
    func aBadSeekIsRefused() async throws {
        let recording = try bundle(initiator: .agent)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        let subject = host()

        for seconds in [-1.0, Double.nan, Double.infinity] {
            guard case .failure(let error) = await subject.handle(
                .editorSeek(bundlePath: recording.url.path, toSeconds: seconds),
                caller: nil) else {
                Issue.record("seek to \(seconds) was accepted"); continue
            }
            #expect(error.code == .invalidArguments)
        }
    }

    // MARK: The CLI surface

    @Test("Every editor verb names its bundle (E8)")
    func everyVerbNamesItsBundle() {
        // WRONG IMPLEMENTATION: letting a verb target "whatever is frontmost"
        // when no path is given. That makes an agent's result depend on window
        // order, which is a property of somebody else's clicking — the same
        // reasoning that makes `snitt_start_recording` refuse to guess between
        // several windows rather than pick the largest.
        for verb in ["open", "play", "pause", "seek", "select"] {
            let parsed = CommandLineParser.parse(["editor", verb])
            guard case .failure = parsed else {
                Issue.record("`editor \(verb)` accepted no bundle path"); continue
            }
        }
    }

    @Test("Editor verbs parse into the requests they name")
    func theParserBuildsTheRightRequests() {
        #expect(CommandLineParser.parse(["editor", "open", "a.snitt"])
            == .success(.editorOpen(bundlePath: "a.snitt")))
        #expect(CommandLineParser.parse(["editor", "seek", "a.snitt", "--to", "4.2"])
            == .success(.editorSeek(bundlePath: "a.snitt", toSeconds: 4.2)))
        #expect(CommandLineParser.parse(
            ["editor", "select", "a.snitt", "--from", "1", "--to", "2"])
            == .success(.editorSelect(bundlePath: "a.snitt",
                                      fromSeconds: 1, toSeconds: 2)))
        #expect(CommandLineParser.parse(["editor", "select", "a.snitt", "--clear"])
            == .success(.editorSelect(bundlePath: "a.snitt",
                                      fromSeconds: nil, toSeconds: nil)))
    }

    @Test("Clearing a selection is spelled out, never inferred from silence")
    func clearingIsExplicit() {
        // WRONG IMPLEMENTATION: treating a bare `editor select <bundle>` as
        // "clear". A caller that forgot its arguments is far more likely than
        // one that meant to clear, and silently clearing a person's selection
        // because an agent sent a malformed command is the kind of thing
        // nobody would think to test for.
        guard case .failure = CommandLineParser.parse(["editor", "select", "a.snitt"]) else {
            Issue.record("a bare `editor select` must not be read as --clear"); return
        }
        guard case .failure = CommandLineParser.parse(
            ["editor", "select", "a.snitt", "--clear", "--from", "1"]) else {
            Issue.record("--clear with --from is contradictory and must be refused"); return
        }
    }

    // MARK: The wire

    @Test("The editor verbs are new REQUEST cases, so the protocol version bumped")
    func theProtocolBumped() {
        // WRONG IMPLEMENTATION: adding request cases without a bump, on the
        // reasoning that earlier additions did not need one. That licence
        // expired when v4 shipped: `AutomationServer` decodes the whole
        // request before comparing versions, so an old app receiving
        // `.editorSeek` reports `internal_error` where §10 wants a refusal
        // that says what to do.
        #expect(AutomationProtocol.version == 5)
    }
}
