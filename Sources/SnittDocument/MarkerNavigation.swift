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

    /// How close the player has to get before a requested jump counts as
    /// landed. Wider than a frame: the seek is exact, the clock is sampled.
    public static let jumpSettledSeconds: Double = 0.05

    /// Where mark-to-mark navigation should reason from, given where the
    /// player actually is and where a jump has asked it to be.
    ///
    /// **The bug this exists for:** a seek is asynchronous, so the player's
    /// clock still reports the old position for a beat after a jump is
    /// requested. Reading it directly meant pressing Next twice quickly found
    /// the same "next" mark both times and seeked to it again — Next advanced
    /// once and then appeared stuck.
    ///
    /// Pure, and separate from the editor, because the interesting part is a
    /// decision about which of two numbers to trust and that needs no player
    /// to get wrong.
    public static func origin(live: Double,
                              pending: Double?) -> (seconds: Double, dropPending: Bool) {
        guard let pending else { return (live, false) }
        // Arrived — or something else moved the playhead there — so the
        // intention has been served and the live clock takes over again.
        if abs(live - pending) < jumpSettledSeconds { return (live, true) }
        return (pending, false)
    }

    /// The mark to jump back to from `time`, or nil if there is none.
    public static func previous(before time: Double, in points: [JumpPoint]) -> JumpPoint? {
        // Measured from the mark you are ON, not from the playhead.
        //
        // This was `last { $0.timeSeconds < time - settleSeconds }`, which
        // reads like the same idiom and is not: it makes the settle a blanket
        // dead zone, so Previous could never reach ANY mark less than half a
        // second back — including the one it had just arrived at, and
        // including the other half of a pause/resume pair. Next uses a 0.01s
        // epsilon, so Next worked and Back appeared stuck, which is exactly
        // how it was reported.
        //
        // The idiom is about the CURRENT track: a little way in, Previous
        // restarts it; at its very start, Previous goes back one. That is a
        // question about the distance from the mark you are sitting on, and
        // nothing to do with how close the one before it happens to be.
        let ordered = ordered(points)
        guard let index = ordered.lastIndex(where: { $0.timeSeconds <= time + epsilon })
        else { return nil }
        let current = ordered[index]
        if time - current.timeSeconds > settleSeconds { return current }
        // Back one — past every mark sharing this instant, so a pause and its
        // resume count as one stop rather than two.
        return ordered[..<index].last { $0.timeSeconds < current.timeSeconds - epsilon }
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
