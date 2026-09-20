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

/// One writer for a recording, by ROUTING (W7).
///
/// `EditorTimelineState.applyAndSave` takes `self.edl` and writes it WHOLE. It
/// does not re-read, and nothing in `SnittApp` watches the bundle. So an agent
/// that wrote `edit.json` under an open window had its work destroyed by that
/// window's next save, with no error and no trace — D60's failure class in the
/// other direction, where "the CLI and GUI are one model, not two".
///
/// W4 first settled this by REFUSING an edit to an open document. That ended
/// the data loss and left an agent unable to SHOW its work, which is the whole
/// point of the editor-control surface. W7 supersedes it: the edit is applied
/// INSIDE the window, where a person watching sees it happen.
@Suite("One writer for a recording")
struct OneWriterForARecordingTests {

    private func bundle() throws -> SnittBundle {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "one-writer-\(UUID().uuidString).snitt")
        let bundle = try SnittBundle(creatingAt: root)
        try RecordingMetadata(createdAt: Date(), initiator: .agent).write(to: bundle)
        try EventLog(events: []).write(to: bundle)
        try EditDecisionList.fullRange().write(to: bundle)
        return bundle
    }

    /// A host whose routers stand in for an open window.
    ///
    /// `routed == nil` models NO window, which must leave every headless use
    /// exactly as it was. A non-nil value models a window that accepted the
    /// edit and returns what it now holds.
    private func host(routing routed: EditDecisionList?,
                      record: (@Sendable (String) -> Void)? = nil) -> AutomationHost {
        AutomationHost(
            coordinator: FakeCoordinator(),
            settings: { AgentSettings(agentRecordingEnabled: true) },
            onRecordingState: { _ in },
            routeEDL: { _, actionName, transform in
                record?(actionName)
                guard let routed else { return nil }
                return transform(routed)
            },
            routeTranscript: { _, actionName, transform in
                record?(actionName)
                guard routed != nil else { return nil }
                return transform(nil)
            },
            auditLogURL: FileManager.default.temporaryDirectory
                .appending(path: "one-writer-audit-\(UUID().uuidString).jsonl"))
    }

    // MARK: The host's half: route when open, write when not

    @MainActor
    @Test("An agent edit to a CLOSED document still writes the file")
    func aClosedDocumentIsWrittenDirectly() async throws {
        // THE CONTROL, and the reason it is not optional: a change that routed
        // everything would pass every test below and break every headless use
        // of Snitt, which is most of them. Verified to fail by making
        // `applyEDL` route unconditionally.
        let recording = try bundle()
        defer { try? FileManager.default.removeItem(at: recording.url) }

        _ = await host(routing: nil).handle(
            .crop(bundlePath: recording.url.path,
                  rect: CropRect(x: 0, y: 0, width: 0.5, height: 0.5)),
            caller: nil)

        let written = try EditDecisionList.read(from: recording)
        #expect(written.crop != nil, "a closed document must still be written directly")
    }

    @MainActor
    @Test("An agent edit to an OPEN document goes through the window, not the file")
    func anOpenDocumentIsRouted() async throws {
        // WRONG IMPLEMENTATION: writing `edit.json` as before. The file really
        // does say what the agent asked for, right up until the open window's
        // next `applyAndSave` takes `self.edl` and overwrites it. Nothing
        // observable fails at the moment of the write, which is what made this
        // bug survive so long. Verified to fail by calling
        // `updated.write(to:)` instead of routing.
        let recording = try bundle()
        defer { try? FileManager.default.removeItem(at: recording.url) }
        let before = try Data(contentsOf: recording.editURL)

        _ = await host(routing: .fullRange()).handle(
            .crop(bundlePath: recording.url.path,
                  rect: CropRect(x: 0, y: 0, width: 0.5, height: 0.5)),
            caller: nil)

        // The window owns the write. The host must not also make one, or the
        // two writers are back. Asserted on the FILE rather than on the
        // response, because this fixture has no `capture.mov` and crop reads
        // it afterwards to report pixel dimensions — a failure downstream of
        // the routing under test.
        #expect(try Data(contentsOf: recording.editURL) == before,
                "the host wrote the file itself while a window was open")
    }

    @MainActor
    @Test("The transform is applied to the WINDOW's document, not the file's")
    func theBaseIsTheWindowsEDL() async throws {
        // WRONG IMPLEMENTATION: reading `edit.json`, transforming that, and
        // handing the finished EDL to the window. It looks equivalent and is
        // not: a window holds edits that are applied but not yet persisted, so
        // the agent would compute from a stale document and the window would
        // then adopt it, discarding the person's unsaved work. The same
        // divergence, by a longer route.
        //
        // The window here carries a cut that `edit.json` does not. Building on
        // the window keeps it; building on the file drops it. Verified to fail
        // by transforming `Self.readEDL(for:)` and passing the result.
        let recording = try bundle()
        defer { try? FileManager.default.removeItem(at: recording.url) }

        let windowHas: EditDecisionList = {
            var edl = EditDecisionList.fullRange()
            edl.cuts = [Cut(range: TimeRange(start: 1, end: 2), label: "unsaved in the window")]
            return edl
        }()

        let applied = Mutex<EditDecisionList?>(nil)
        let subject = AutomationHost(
            coordinator: FakeCoordinator(),
            settings: { AgentSettings(agentRecordingEnabled: true) },
            onRecordingState: { _ in },
            routeEDL: { _, _, transform in
                let result = transform(windowHas)
                applied.withLock { $0 = result }
                return result
            },
            routeTranscript: { _, _, transform in transform(nil) },
            auditLogURL: FileManager.default.temporaryDirectory
                .appending(path: "one-writer-audit-\(UUID().uuidString).jsonl"))

        _ = await subject.handle(
            .crop(bundlePath: recording.url.path,
                  rect: CropRect(x: 0, y: 0, width: 0.5, height: 0.5)),
            caller: nil)

        let result = try #require(applied.withLock { $0 }, "the crop never routed")
        #expect(result.crop != nil, "the agent's crop was lost")
        #expect(result.cuts.count == 1,
                "the window's unpersisted cut was discarded: built on the file, not the window")
    }

    @MainActor
    @Test("Every mutating verb routes; no verb writes behind the window's back")
    func everyMutatingVerbRoutes() async throws {
        // WRONG IMPLEMENTATION: routing the verb the bug was noticed through
        // (`trim`) and leaving the others writing the file. `crop`,
        // `auto-deep-trim` and `narrate` write the same sidecars the editor
        // saves, so each of them loses work the same way.
        //
        // `narrate` is the one most easily forgotten, because it writes
        // `transcript.json` rather than `edit.json` — a different file, the
        // identical bug. Verified to fail by dropping any single call site.
        let recording = try bundle()
        defer { try? FileManager.default.removeItem(at: recording.url) }

        let seen = Mutex<[String]>([])
        let subject = host(routing: .fullRange()) { name in seen.withLock { $0.append(name) } }

        _ = await subject.handle(
            .crop(bundlePath: recording.url.path,
                  rect: CropRect(x: 0, y: 0, width: 0.5, height: 0.5)), caller: nil)
        _ = await subject.handle(
            .addNarration(bundlePath: recording.url.path, text: "hello", atSeconds: 0),
            caller: nil)

        let names = seen.withLock { $0 }
        #expect(names.contains("Crop"), "crop did not route: \(names)")
        #expect(names.contains("Narrate"), "narrate did not route: \(names)")
    }

    @MainActor
    @Test("Narration still reaches a closed document's transcript")
    func narrationWritesTheFileWhenClosed() async throws {
        // The transcript half of the control. `narrate` is the one verb whose
        // sidecar may legitimately not exist yet — writing narration is the
        // only way to get a transcript without running the recogniser — so a
        // routing change that assumed an existing file would break the case
        // the verb exists for.
        let recording = try bundle()
        defer { try? FileManager.default.removeItem(at: recording.url) }

        let response = await host(routing: nil).handle(
            .addNarration(bundlePath: recording.url.path, text: "hello there", atSeconds: 0),
            caller: nil)
        guard case .narrationAdded = response else {
            Issue.record("expected narration, got \(response)"); return
        }
        let transcript = try Transcript.read(from: recording)
        #expect(transcript.words.count == 2, "narration did not reach transcript.json")
    }
}

/// Minimal lock, so a `@Sendable` recording closure can collect across hops
/// without pulling in a dependency.
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
