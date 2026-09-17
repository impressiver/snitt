// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Darwin
import Foundation
import Security

/// Who is on the other end of the automation socket.
///
/// **The socket is the real privacy boundary, and it had no identity on it.**
/// `AutomationServer` accepted with `accept(fd, nil, nil)` and asked nothing
/// about the caller, while the app behind it holds Screen Recording and an
/// Input Monitoring event tap. TCC grants those to *this application*, so any
/// same-user process that can reach the socket — an npm postinstall, an editor
/// extension, an unsigned binary with no grants of its own — could act through
/// a deputy that has them. That is the shape TCC exists to prevent.
///
/// The system picker blunts the worst of it: `RecordingCoordinator` resolves
/// every target through `PickerTargetResolver`, so a caller cannot capture
/// anything silently. It does NOT cover reads of recordings already on disk,
/// and it does not tell an incident reviewer who asked.
///
/// So this is deliberately about ATTRIBUTION first, enforcement second. §12
/// promises "an agent-side incident can be reconstructed even though no human
/// watched it happen", and an audit line reading `"initiator": "agent"` cannot
/// keep that promise — every caller looks identical. Knowing the pid, the
/// binary and its signing identity is what makes the promise true, and it is
/// also the input any future per-caller approval would need.
public struct PeerIdentity: Sendable, Equatable {
    public let pid: pid_t
    public let uid: uid_t
    /// Absolute path to the calling executable, when the kernel will say.
    public let executablePath: String?
    /// The caller's code-signing identifier, e.g. `com.apple.Terminal`.
    /// `nil` for an unsigned binary — which is itself worth recording.
    public let signingIdentifier: String?
    /// The Apple Developer team the caller is signed by, when it has one.
    public let teamIdentifier: String?

    public init(pid: pid_t, uid: uid_t, executablePath: String?,
                signingIdentifier: String?, teamIdentifier: String?) {
        self.pid = pid
        self.uid = uid
        self.executablePath = executablePath
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
    }

    /// One line for `audit.jsonl`.
    ///
    /// Unsigned callers say so explicitly rather than leaving the field out:
    /// an absent field reads as "not recorded", and the difference between
    /// "we did not look" and "it was unsigned" is the whole value of the
    /// record when someone is reading it after the fact.
    public var auditDescription: String {
        let binary = executablePath ?? "unknown"
        let signature: String
        switch (signingIdentifier, teamIdentifier) {
        case let (id?, team?): signature = "\(id) (\(team))"
        case let (id?, nil): signature = "\(id) (no team)"
        default: signature = "unsigned"
        }
        return "pid \(pid) uid \(uid) \(binary) [\(signature)]"
    }
}

public enum PeerIdentityReader {

    /// The identity of the process connected on `fd`, or nil if the kernel
    /// will not say.
    ///
    /// Reads the credentials the KERNEL holds for the connected socket, never
    /// anything the caller sends. A peer that could state its own pid could
    /// state any pid; the point of `LOCAL_PEERPID` is that it cannot be
    /// forged from user space.
    public static func identity(ofPeerOn fd: Int32) -> PeerIdentity? {
        guard let pid = peerPID(fd) else { return nil }
        let uid = peerUID(fd) ?? 0
        let path = executablePath(of: pid)
        let signing = signingIdentity(of: pid)
        return PeerIdentity(pid: pid, uid: uid, executablePath: path,
                            signingIdentifier: signing.identifier,
                            teamIdentifier: signing.team)
    }

    private static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0
        else { return nil }
        return pid
    }

    private static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return uid
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        // `proc_pidpath` returns the length it WROTE, not counting the
        // terminator, so the string is exactly that many bytes — decoded
        // directly rather than scanned for a NUL.
        //
        // `String(cString:)` is deprecated in Swift 6.4 and this project
        // builds with warnings-as-errors in CI, so the deprecation is a build
        // failure rather than a note. Its replacement cannot be handed a
        // NUL-terminated buffer: `String(decoding:as:)` keeps every byte it is
        // given, so passing the whole 1024-byte buffer would produce a path
        // with a thousand NULs welded to the end, which compares equal to
        // nothing and prints as the right answer.
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
                      as: UTF8.self)
    }

    /// The caller's signing identifier and team, via the Security framework.
    ///
    /// Both nil means unsigned, ad-hoc signed, or gone — all of which the
    /// audit line reports as "unsigned", because from the reviewer's side
    /// they are the same fact: nothing vouches for this binary.
    private static func signingIdentity(of pid: pid_t) -> (identifier: String?, team: String?) {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return (nil, nil) }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return (nil, nil) }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return (nil, nil) }

        let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        return (identifier, team)
    }
}
