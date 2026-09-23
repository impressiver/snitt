// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// What an open document should do about a sidecar that changed on disk.
///
/// Three values, and the window needs all three: adopting unconditionally would
/// discard unsaved work (the loss W7 exists to prevent, arriving from the other
/// direction), while never adopting is the staleness this is fixing.
public enum DiskReconciliation: Equatable, Sendable {
    /// Disk already says what the window says. The common case by far, because
    /// it is also what the window's OWN save looks like from the outside.
    case inSync
    /// The window has nothing unsaved, so disk wins with nothing lost.
    case adopt
    /// Disk and the window disagree AND the window's version was never saved.
    /// Something has to give, and it is not this code's call which.
    case conflict
}

extension DiskReconciliation {
    /// - Parameters:
    ///   - onDisk: what the sidecar says now.
    ///   - live: what the window is showing, saved or not.
    ///   - lastSaved: the last value this window wrote, so "the window has
    ///     unsaved changes" is `live != lastSaved`.
    ///
    /// **`onDisk == live` is checked FIRST, and that ordering is what makes the
    /// window's own writes free.** A save is an external change as far as the
    /// filesystem is concerned: the watcher fires, and for the moment between
    /// the bytes landing and `lastSaved` being updated, disk and `lastSaved`
    /// disagree. Comparing against `live` too means that window reads as
    /// in-sync rather than as a conflict with itself, so no bookkeeping,
    /// suppression flag or timing window is needed to tell our writes from
    /// everyone else's. It is also self-correcting: a missed event costs
    /// nothing, because the next one re-derives the same answer from the same
    /// three values.
    public static func decide<Value: Equatable>(onDisk: Value,
                                                live: Value,
                                                lastSaved: Value) -> DiskReconciliation {
        if onDisk == live { return .inSync }
        return live == lastSaved ? .adopt : .conflict
    }
}
