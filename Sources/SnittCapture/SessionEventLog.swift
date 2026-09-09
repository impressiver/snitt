// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittDocument

/// Everything timestamped that happens during a recording: markers a human or
/// agent deliberately drops (§4.12), and the fact that input occurred (§4.2).
///
/// An actor because entries arrive from the automation socket's connection
/// threads, from the main actor's hotkey, and from the event tap's own run-loop
/// thread, while the writer reads them at stop.
///
/// Renamed from `MarkerLog` when input events joined it — the old name would
/// have sent anyone looking for "where input events are stored" to the wrong
/// place.
public actor SessionEventLog {
    private var events: [LoggedEvent] = []

    public init() {}

    /// The quantum non-marker timestamps are rounded to, in seconds.
    ///
    /// The tap is `.cgSessionEventTap` — session-wide — while the video is
    /// window-scoped, so an event can describe typing that happened in a window
    /// deliberately kept out of frame. At full `Double` precision that log
    /// carries inter-keystroke intervals for text the video does not contain: a
    /// timing side channel over, say, a master password typed off-camera
    /// mid-recording. §5.1's "a password banner must not reach the file"
    /// argument applies to `events.json` exactly as it applies to the pixels.
    ///
    /// 100 ms costs the only consumer nothing: `--auto-trim` reasons about dead
    /// air in seconds.
    public static let inputTimeQuantum: Double = 0.1

    public func add(at timeSeconds: Double, kind: EventKind, label: String?,
                    x: Double? = nil, y: Double? = nil,
                    source: EventSource = .observed) {
        // Both privacy rules live at this one boundary, deliberately: a future
        // writer cannot route around one by adding a second call site.
        //
        // 1. Input events are stripped of any label rather than trusting
        //    callers. A label is the only place key identity or click content
        //    could reach the file, and events.json travels with the bundle in
        //    plaintext — see this plan's ruling and §5.1.
        // 2. Input timestamps are quantised. Markers keep full precision:
        //    their times are deliberate, authored, and a reviewer jumps
        //    straight to them, so blunting them would cost something real.
        //
        // Reported input (`source == .reported`) goes through BOTH rules
        // unchanged, deliberately. Its label is stripped like any other input
        // event's: an agent describing what it clicked would put click content
        // into a plaintext file that travels with the bundle, which is the
        // exact thing rule 1 exists to stop, and the fact that a well-meaning
        // caller supplied it is not a reason to trust it. Narration has a
        // home already — a marker, which is authored, labelled and keeps full
        // precision.
        //
        // The COORDINATES are new and carry no such risk: a fraction of the
        // window says where, never what, and for a reported event the caller
        // knew it already.
        let isMarker = (kind == .marker)
        let safeLabel = isMarker ? label : nil
        let safeTime = isMarker ? timeSeconds : Self.quantised(timeSeconds)
        events.append(LoggedEvent(timeSeconds: safeTime, kind: kind, label: safeLabel,
                                  x: x, y: y, source: source))
    }

    /// Rounds to the nearest `inputTimeQuantum`.
    ///
    /// Written as multiply-round-divide rather than `rounded(.toNearestOrEven)`
    /// on a scaled value so the result is the double nearest a short decimal
    /// (0.3, not 0.30000000000000004) — `events.json` is read by humans.
    public static func quantised(_ timeSeconds: Double) -> Double {
        let steps = (timeSeconds / inputTimeQuantum).rounded()
        return steps / (1.0 / inputTimeQuantum)
    }

    public func snapshot() -> [LoggedEvent] { events }

    public func counts() -> (markers: Int, inputEvents: Int) {
        let markers = events.filter { $0.kind == .marker }.count
        return (markers: markers, inputEvents: events.count - markers)
    }
}
