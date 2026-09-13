// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Darwin
import Foundation
@testable import SnittAutomation

/// Reading the caller's identity off a live socket.
///
/// Tested against a REAL `socketpair`, not a stub. The whole value of
/// `LOCAL_PEERPID` is that it comes from the kernel rather than from anything
/// the peer says, and a fake fd would test the one property that does not
/// matter — that the code compiles — while asserting nothing about whether the
/// kernel actually answers.
struct PeerIdentityTests {

    /// A connected AF_UNIX pair. Both ends live in THIS process, so the pid
    /// the kernel reports is one this test can compare against `getpid()`
    /// rather than against a number it made up.
    private func connectedPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        try #require(result == 0, "socketpair failed: \(String(cString: strerror(errno)))")
        return (fds[0], fds[1])
    }

    @Test("The pid comes from the kernel and is the real peer")
    func pidIsTheRealPeer() throws {
        let (a, b) = try connectedPair()
        defer { close(a); close(b) }

        let identity = try #require(PeerIdentityReader.identity(ofPeerOn: a),
                                    "the kernel would not report a peer at all")
        // Both ends are this process, so this is a value the test can check
        // rather than merely observe. An implementation that returned 0, or
        // read something the peer sent, fails here.
        #expect(identity.pid == getpid(), "peer pid was \(identity.pid), expected \(getpid())")
        #expect(identity.uid == getuid())
    }

    @Test("The calling executable is identified")
    func executablePathIsResolved() throws {
        let (a, b) = try connectedPair()
        defer { close(a); close(b) }

        let identity = try #require(PeerIdentityReader.identity(ofPeerOn: a))
        let path = try #require(identity.executablePath,
                                "no executable path — an audit record could not name the caller")
        // Compared against the process's own path rather than a substring
        // guess: under `swift test` the runner's name is not something this
        // test should be encoding.
        #expect(path == ProcessInfo.processInfo.arguments[0]
                || FileManager.default.fileExists(atPath: path),
                "executable path does not exist on disk: \(path)")
    }

    @Test("A dead socket yields no identity rather than a fabricated one")
    func closedSocketIsNil() throws {
        let (a, b) = try connectedPair()
        close(a)
        close(b)
        // The failure that matters is not a crash — it is returning a
        // plausible-looking identity for a peer that is not there, which would
        // put a fictional caller into the audit log.
        #expect(PeerIdentityReader.identity(ofPeerOn: a) == nil)
        #expect(PeerIdentityReader.identity(ofPeerOn: -1) == nil)
    }

    @Test("An unsigned caller is recorded as unsigned, not as missing")
    func unsignedIsStated() {
        // "We did not look" and "it was unsigned" are different facts, and the
        // difference is the whole value of the line when someone reads it after
        // an incident. An absent field cannot express the second.
        let unsigned = PeerIdentity(pid: 501, uid: 502, executablePath: "/tmp/thing",
                                    signingIdentifier: nil, teamIdentifier: nil)
        #expect(unsigned.auditDescription.contains("unsigned"))
        #expect(unsigned.auditDescription.contains("pid 501"))
        #expect(unsigned.auditDescription.contains("/tmp/thing"))
    }

    @Test("A signed caller records its identifier and team")
    func signedIsAttributed() {
        let signed = PeerIdentity(pid: 7, uid: 501, executablePath: "/Applications/Foo.app/x",
                                  signingIdentifier: "com.example.foo",
                                  teamIdentifier: "ABCDE12345")
        #expect(signed.auditDescription.contains("com.example.foo"))
        #expect(signed.auditDescription.contains("ABCDE12345"))
        #expect(!signed.auditDescription.contains("unsigned"),
                "a signed caller was described as unsigned")
    }

    @Test("A signed caller with no team is distinguished from an unsigned one")
    func signedWithoutTeamIsItsOwnCase() {
        // Ad-hoc and self-signed binaries land here. Collapsing them into
        // "unsigned" would lose the identifier, which is the only thing that
        // distinguishes two ad-hoc binaries from each other.
        let adHoc = PeerIdentity(pid: 9, uid: 501, executablePath: "/tmp/adhoc",
                                 signingIdentifier: "adhoc-tool", teamIdentifier: nil)
        #expect(adHoc.auditDescription.contains("adhoc-tool"))
        #expect(adHoc.auditDescription.contains("no team"))
        #expect(!adHoc.auditDescription.contains("unsigned"))
    }
}
