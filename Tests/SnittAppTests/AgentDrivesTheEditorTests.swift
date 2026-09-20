// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
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
            .editorOpen(bundlePath: recording.url.path, widthPoints: nil, heightPoints: nil), caller: nil)
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
            .editorOpen(bundlePath: recording.url.path, widthPoints: nil, heightPoints: nil), caller: nil)
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
            ("open", .editorOpen(bundlePath: recording.url.path, widthPoints: nil, heightPoints: nil)),
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
            == .success(.editorOpen(bundlePath: "a.snitt", widthPoints: nil, heightPoints: nil)))
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

    // MARK: Cutting what was selected

    @MainActor
    @Test("Cutting with nothing selected is refused, not reported as done")
    func cutWithNoSelectionIsRefused() async throws {
        // WRONG IMPLEMENTATION: reusing `cutSelection()`, which is a no-op
        // with no selection. That is right for a KEYSTROKE — pressing Delete
        // with nothing selected is a harmless mistake — and wrong for a
        // COMMAND: an agent cannot see the timeline, so "cut" and "cut
        // nothing" reported identically is §8's confidently-wrong outcome.
        let recording = try bundle(initiator: .agent)
        defer { try? FileManager.default.removeItem(at: recording.url) }

        // Not open, so this exercises the earlier guard; the selection guard
        // is unreachable from a host test without a real window, and is
        // covered by the editor-level behaviour instead.
        guard case .failure(let error) = await host().handle(
            .editorCut(bundlePath: recording.url.path), caller: nil) else {
            Issue.record("cutting a closed document must fail"); return
        }
        #expect(error.code == .targetNotFound)
    }

    @Test("`editor cut` parses, and takes nothing but a bundle")
    func cutParses() {
        #expect(CommandLineParser.parse(["editor", "cut", "a.snitt"])
            == .success(.editorCut(bundlePath: "a.snitt")))
        guard case .failure = CommandLineParser.parse(["editor", "cut"]) else {
            Issue.record("`editor cut` must name its bundle"); return
        }
    }

    @Test("An interior span is reachable at all")
    func anInteriorSpanIsReachable() {
        // THE REASON THIS VERB EXISTS, pinned so it cannot quietly regress to
        // the state the demo hit: `trim` sets the range to KEEP, so it removes
        // material only from the ENDS, and `auto-deep-trim` finds dead air
        // rather than a span the caller chose. With neither able to remove a
        // chosen interior range, `editor select` was a highlight nothing could
        // act on.
        //
        // Found by filming the demo, where "select the stumble, cut it" was
        // the central beat and turned out to be unreachable. `snitt trim
        // --start 0 --end 9` removed the stumble AND everything after it.
        guard case .success(.editorCut) = CommandLineParser.parse(
            ["editor", "cut", "a.snitt"]) else {
            Issue.record("no verb removes a chosen interior span"); return
        }
    }

    // MARK: Sizing the window before filming it (D110)

    @MainActor
    @Test("A requested size is centred, and raised to the window's own minimum")
    func aRequestedSizeIsClampedToTheFloor() {
        // WRONG IMPLEMENTATION: inventing a minimum here. The window already
        // has `minimumContentSize`, derived from what the rail and panes need
        // with a flat 800x600 under it, measured from where the transport row
        // started dropping controls. A second answer drifts from the first,
        // and a LOWER one hands an agent a size macOS silently overrides —
        // so the agent films a window with the wrong dimensions and nothing
        // says so.
        let screen = NSRect(x: 0, y: 0, width: 2000, height: 1400)
        let tiny = EditorWindowController.requestedContentRect(
            width: 200, height: 150, on: screen)
        let floor = EditorWindowController.minimumContentSize
        #expect(tiny.width == floor.width)
        #expect(tiny.height == floor.height)
        #expect(floor.width >= 800, "the floor moved: \(floor)")
    }

    @MainActor
    @Test("A size larger than the screen is clamped to it")
    func aRequestedSizeIsClampedToTheScreen() {
        // WRONG IMPLEMENTATION: obeying the request. A window bigger than the
        // space it sits in cannot be filmed whole, and controlling what the
        // frame contains is the entire reason for asking.
        let screen = NSRect(x: 0, y: 0, width: 1400, height: 900)
        let huge = EditorWindowController.requestedContentRect(
            width: 9000, height: 9000, on: screen)
        #expect(huge.width == 1400)
        #expect(huge.height == 900)
    }

    @MainActor
    @Test("A requested size is centred on the screen it is given")
    func aRequestedSizeIsCentred() {
        let screen = NSRect(x: 100, y: 50, width: 2000, height: 1400)
        let rect = EditorWindowController.requestedContentRect(
            width: 1000, height: 700, on: screen)
        #expect(rect.midX == screen.midX)
        #expect(rect.midY == screen.midY)
    }

    @MainActor
    @Test("No screen still yields the requested size, not a crash or a zero")
    func noScreenStillSizes() {
        // A test host has no screen and `NSScreen.main` is nil there, which is
        // why this function takes the frame rather than reading it.
        let rect = EditorWindowController.requestedContentRect(
            width: 1000, height: 700, on: nil)
        #expect(rect.width == 1000)
        #expect(rect.height == 700)
    }

    @MainActor
    @Test("Half a size is refused, not completed from the screen")
    func halfASizeIsRefused() async throws {
        // WRONG IMPLEMENTATION: filling the missing side from the screen or
        // from the aspect ratio. That is a window the caller did not ask for
        // and cannot tell apart from the one it wanted.
        let recording = try bundle(initiator: .agent)
        defer { try? FileManager.default.removeItem(at: recording.url) }

        guard case .failure(let error) = await host().handle(
            .editorOpen(bundlePath: recording.url.path,
                        widthPoints: 900, heightPoints: nil), caller: nil) else {
            Issue.record("half a size must be refused"); return
        }
        #expect(error.code == .invalidArguments)
    }

    @MainActor
    @Test("A zero or non-finite size is refused")
    func aBadSizeIsRefused() async throws {
        let recording = try bundle(initiator: .agent)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        let subject = host()

        for (w, h) in [(0.0, 600.0), (-900.0, 600.0), (900.0, Double.nan)] {
            guard case .failure(let error) = await subject.handle(
                .editorOpen(bundlePath: recording.url.path,
                            widthPoints: w, heightPoints: h), caller: nil) else {
                Issue.record("\(w)x\(h) was accepted"); continue
            }
            #expect(error.code == .invalidArguments)
        }
    }

    @Test("`editor open` parses a size, and refuses half of one")
    func sizeParses() {
        #expect(CommandLineParser.parse(
            ["editor", "open", "a.snitt", "--width", "900", "--height", "640"])
            == .success(.editorOpen(bundlePath: "a.snitt",
                                    widthPoints: 900, heightPoints: 640)))
        #expect(CommandLineParser.parse(["editor", "open", "a.snitt"])
            == .success(.editorOpen(bundlePath: "a.snitt",
                                    widthPoints: nil, heightPoints: nil)))
        guard case .failure = CommandLineParser.parse(
            ["editor", "open", "a.snitt", "--width", "900"]) else {
            Issue.record("half a size must be refused at the parser too"); return
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
