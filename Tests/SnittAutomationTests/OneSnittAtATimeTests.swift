// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittAutomation

private func tempSocketURL() -> URL {
    // Short path: a Unix socket path is limited to ~104 bytes.
    URL(fileURLWithPath: "/tmp/snitt-one-\(UUID().uuidString.prefix(8)).sock")
}

/// One Snitt at a time.
///
/// Three copies of `Snitt.app` on a machine gave three menubar accessories,
/// because LaunchServices decides "already running" by bundle PATH and the app
/// had nothing to say about it. Each new instance then unlinked the automation
/// socket and bound its own, so the older ones stayed alive, kept their hotkeys
/// and their menubar item, and silently stopped receiving anything.
@Suite("One Snitt at a time")
struct OneSnittAtATimeTests {

    // MARK: The socket half

    @Test("A second server refuses the path rather than taking it")
    func aLiveSocketIsNotStolen() throws {
        // WRONG IMPLEMENTATION, and the one that shipped: unlink whatever is at
        // the path, then bind. It succeeds, which is the problem — the second
        // server is serving and the first is holding an fd on an inode with no
        // name, unreachable and unaware. Verified to fail by restoring the
        // unconditional `removeItem`.
        let url = tempSocketURL()
        let first = AutomationServer(socketURL: url, handler: SpyHandler())
        try first.start()
        defer { first.stop() }

        let second = AutomationServer(socketURL: url, handler: SpyHandler())
        #expect(throws: ServerError.alreadyServing) { try second.start() }

        // And the incumbent is still the one on the path. Without this the test
        // passes for a server that threw on the way to breaking things anyway.
        #expect(AutomationClient.canConnect(to: url.path),
                "the incumbent lost the socket even though the newcomer refused")
    }

    @Test("A socket file left by a dead server is still cleared")
    func staleDebrisIsRemoved() throws {
        // THE CONTROL, and the reason the old code existed. A Unix socket's
        // inode outlives its process, so refusing on file presence alone would
        // mean Snitt could never start twice in a row — a far worse bug than
        // the one being fixed, and the shape the client half already hit from
        // the other side.
        let url = tempSocketURL()
        let dead = AutomationServer(socketURL: url, handler: SpyHandler())
        try dead.start()
        dead.stop()
        // `stop()` tidies up after itself, so put the debris back by hand: this
        // must hold for the crash case, where nothing tidied anything.
        FileManager.default.createFile(atPath: url.path, contents: Data())
        #expect(FileManager.default.fileExists(atPath: url.path))

        let next = AutomationServer(socketURL: url, handler: SpyHandler())
        #expect(throws: Never.self) { try next.start() }
        next.stop()
    }

    @Test("Liveness is a connect, never the file being there")
    func livenessIsNotFilePresence() throws {
        let url = tempSocketURL()
        FileManager.default.createFile(atPath: url.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(SocketLiveness.isListening(at: url.path) == false,
                "a file that nobody is accepting on read as a live listener")
    }

    // MARK: The decision half

    @Test("Alone, it just starts")
    func aloneItProceeds() {
        #expect(InstanceDecision.decide(otherInstancesRunning: false,
                                        incumbentIsRecording: nil) == .proceed)
        // Whatever the probe says is irrelevant when there is nobody to probe.
        #expect(InstanceDecision.decide(otherInstancesRunning: false,
                                        incumbentIsRecording: true) == .proceed)
    }

    @Test("The newcomer takes over an idle incumbent")
    func theNewcomerWins() {
        // The case that makes a rebuild usable: `build/Snitt.app` opened while
        // the installed copy sits idle has to be the one you end up looking at.
        #expect(InstanceDecision.decide(otherInstancesRunning: true,
                                        incumbentIsRecording: false) == .replaceIncumbent)
    }

    @Test("A recording outranks the newcomer")
    func aRecordingIsNotInterrupted() {
        // The one exception, and the reason the probe exists at all.
        // `applicationShouldTerminate` flushes pending saves and says nothing
        // about an `AVAssetWriter` mid-file, so quitting here loses the take.
        #expect(InstanceDecision.decide(otherInstancesRunning: true,
                                        incumbentIsRecording: true) == .deferToIncumbent)
    }

    @Test("An incumbent that will not answer is left alone")
    func silenceIsNotConsent() {
        // THE ONE THIS CHANGED, after a real session. The first version read
        // an unreachable incumbent as fair game, on the reasoning that an app
        // which will not answer its own socket cannot be stopped or inspected
        // anyway. That weighed the wrong risk.
        //
        // The probe reaches the recorder actor through the main actor, and
        // during capture — editor open, frames arriving — both are busy. "No
        // answer" describes a working app under load at least as often as a
        // wedged one, and the costs are not symmetric: guess "idle" about a
        // recording app and the take is gone (no sidecars, no moov atom,
        // measured); guess "busy" about a wedged one and somebody clicks Quit.
        #expect(InstanceDecision.decide(otherInstancesRunning: true,
                                        incumbentIsRecording: nil) == .deferToIncumbent)
    }

    @Test("Only an incumbent that SAYS it is idle is replaced")
    func onlyAConfirmedIdleIncumbentIsReplaced() {
        // The invariant behind both branches above, stated once so a later
        // change cannot satisfy them separately and still authorise a kill on
        // a maybe. Exactly one input may terminate anything.
        let terminating = [true, false, nil].filter {
            InstanceDecision.decide(otherInstancesRunning: true,
                                    incumbentIsRecording: $0) == .replaceIncumbent
        }
        #expect(terminating == [false],
                "something other than a confirmed idle incumbent authorised a takeover")
    }
}
