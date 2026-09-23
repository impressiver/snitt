// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Whether anything is listening on a Unix socket PATH right now.
///
/// **The file is not the answer.** A Unix socket's inode outlives the process
/// that bound it: quit Snitt and the path is still there, so a presence check
/// reports "running" forever after the first launch. Only a connect
/// distinguishes a live listener from the debris of a dead one.
///
/// This lived on the client, where the rule was learned — its header noted that
/// the first version of the launch guard tested for the file and therefore
/// never fired. The server made the SAME mistake in the other direction,
/// unlinking whatever was at the path before binding on the theory that
/// anything there must be stale, which let a second Snitt take the channel away
/// from a live one without either of them noticing. One helper, so the rule has
/// one place to be wrong.
enum SocketLiveness {
    /// Connect-and-close. `false` for a path that is absent, is not a socket,
    /// or is a socket nobody is accepting on.
    static func isListening(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else { return false }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLength) { cptr in
                path.withCString { strcpy(cptr, $0) }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        return result == 0
    }
}
