// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// Stepping between marks (D84).
///
/// Marks are how you move through a Snitt recording — they carry
/// agent-authored labels, which is the thing `snitt_inspect` reads and the
/// thing competitors do not have. Until now the only way to reach one was
/// clicking a row in the chapters list.
///
/// Everything here is in OUTPUT time, matching `PreviewController.jumpPoints`
/// and the playhead. Source time would put every answer at the wrong instant
/// the moment anything was cut.
public enum MarkerNavigation {

    /// How far past a mark you must be before "previous" means *this* mark
    /// rather than the one before it.
    ///
    /// The music-player idiom, and people already have it in their fingers:
    /// pressing Previous a little way into a track restarts that track;
    /// pressing it twice goes back one. Without this, Previous from just after
    /// a mark skips the mark you were listening to — which is the one you
    /// almost certainly meant.
    public static let settleSeconds: Double = 0.5

    /// Guards against re-selecting the mark you are already sitting on when
    /// floating-point noise puts the playhead a hair before it.
    private static let epsilon: Double = 0.01

    /// The mark to jump back to from `time`, or nil if there is none.
    public static func previous(before time: Double, in points: [JumpPoint]) -> JumpPoint? {
        ordered(points).last { $0.timeSeconds < time - settleSeconds }
    }

    /// The next mark after `time`, or nil at the last one.
    public static func next(after time: Double, in points: [JumpPoint]) -> JumpPoint? {
        ordered(points).first { $0.timeSeconds > time + epsilon }
    }

    /// The mark the playhead is currently within — the most recent one at or
    /// before `time`. What the transport's readout names.
    public static func current(at time: Double, in points: [JumpPoint]) -> JumpPoint? {
        ordered(points).last { $0.timeSeconds <= time + epsilon }
    }

    /// Sorted by time. Events arrive in log order, and dragging a marker
    /// earlier on the timeline does not reorder that array.
    ///
    /// It does NOT deduplicate. An earlier version did, on the theory that two
    /// markers collapsed onto one fold would make Next stop twice at the same
    /// instant — but `epsilon` already handles that: from a mark at 5.0,
    /// `next` looks for `> 5.01` and skips every other mark at 5.0 too. The
    /// dedupe was dead weight with a doc comment asserting the opposite, and a
    /// mutant that removed it survived, which is how it was found.
    private static func ordered(_ points: [JumpPoint]) -> [JumpPoint] {
        points.sorted { $0.timeSeconds < $1.timeSeconds }
    }
}
