// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
import AppKit
@testable import SnittApp

/// Quitting finishes the recording instead of abandoning it.
///
/// `stopIfRecording` had exactly ONE caller — the status item's own Quit — so
/// every other route terminated straight through a capture in flight: ⌘Q, the
/// Dock, an Apple Event (`osascript`), and logging out or restarting, which
/// sends that same event to every app.
///
/// What that left, measured on a real recording rather than inferred: a
/// `capture.mov` with no moov atom, which nothing can open; no `meta.json`, no
/// `events.json`, no `edit.json`, so the markers went too; `snitt inspect`
/// answering `unusable_recording`; and an audit entry with a start and no end.
/// Not a shortened take. No take.
@Suite(.serialized)
@MainActor
struct QuitFinishesTheTakeTests {
    init() { _ = NSApplication.shared }

    @Test("A quit with nothing in flight still does not wait")
    func anIdleQuitIsImmediate() {
        // THE CONTROL, and it guards a real regression: a delegate that always
        // answered `.terminateLater` would make every ordinary quit depend on a
        // reply arriving, so a bug in the flush path becomes an app that cannot
        // be quit at all.
        let delegate = AppDelegate()
        delegate.noteCapture(.idle)
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
    }

    @Test("A quit during a recording waits for it")
    func aRecordingDefersTheQuit() async {
        // Verified to fail by restoring `guard EditorWindowController
        // .hasPendingSaves`: the delegate answers `.terminateNow` and AppKit
        // tears the process down with the writer still open.
        let delegate = AppDelegate()
        var replies: [Bool] = []
        delegate.replyToTerminate = { replies.append($0) }

        delegate.noteCapture(.recording(startedAt: Date()))
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater,
                "quit did not wait for a recording in flight")

        await delegate.waitForTerminationFlushForTesting()
        #expect(replies == [true], "AppKit must be told to go ahead exactly once")
    }

    @Test("A PAUSED recording also holds the quit")
    func aPausedRecordingDefersTheQuit() async {
        // A pause is the absence of buffers, not the absence of a writer: the
        // `AVAssetWriter` is still open and still unfinalized. And pausing is
        // exactly what an agent does before it goes away to think, so this is
        // the state a recording is most likely to be sitting in when something
        // decides to quit.
        let delegate = AppDelegate()
        delegate.replyToTerminate = { _ in }
        delegate.noteCapture(.paused(startedAt: Date(), pausedSeconds: 2))
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
        await delegate.waitForTerminationFlushForTesting()
    }

    @Test("A stop already under way holds the quit too")
    func stoppingDefersTheQuit() async {
        // `.stopping` is a finalize in progress. Terminating through it aborts
        // the moov atom write, which is the same loss by a narrower window —
        // and "press stop, then immediately ⌘Q" is an ordinary thing to do.
        let delegate = AppDelegate()
        delegate.replyToTerminate = { _ in }
        delegate.noteCapture(.stopping)
        #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
        await delegate.waitForTerminationFlushForTesting()
    }

    @Test("An AGENT recording is mirrored, not just a hotkey one")
    func agentRecordingsCountToo() {
        // The mirror next to this one, `recordingStartedAt`, is written only on
        // the hotkey path. A quit guard built the same way would read "idle"
        // for every agent-initiated recording — precisely the ones with nobody
        // at the machine to notice them being thrown away. Asserted through the
        // state the AUTOMATION host publishes.
        let delegate = AppDelegate()
        delegate.noteCapture(.recording(startedAt: Date()))
        #expect(delegate.isCapturing, "an agent's recording did not register")
        delegate.noteCapture(.idle)
        #expect(!delegate.isCapturing)
    }

    @Test("Every non-idle state must be finished before quitting")
    func onlyIdleIsSafeToQuitThrough() {
        // Stated once, over the whole enum, so a state added later cannot
        // quietly default to "safe to terminate through". That is how
        // `.paused` would have been missed.
        let held: [RecordingState] = [
            .recording(startedAt: Date()),
            .paused(startedAt: Date(), pausedSeconds: 1),
            .stopping,
        ]
        let safeToQuitThrough = held.filter { !$0.mustFinishBeforeQuit }
        #expect(safeToQuitThrough.isEmpty,
                "these would be terminated through: \(safeToQuitThrough)")
        #expect(!RecordingState.idle.mustFinishBeforeQuit)
    }
}
