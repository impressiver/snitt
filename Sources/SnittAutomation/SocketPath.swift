// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Where the automation socket lives.
///
/// Application Support rather than `/tmp`: `/tmp` is world-writable, so another
/// user on a shared machine could create the path first and receive an agent's
/// recording requests. Application Support is per-user and not writable by others.
public enum SocketPath {
    public static func url() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Snitt", isDirectory: true)
        try? FileManager.default.createDirectory(at: base,
                                                 withIntermediateDirectories: true)
        return base.appendingPathComponent("automation.sock")
    }
}
