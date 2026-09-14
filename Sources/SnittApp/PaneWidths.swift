// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// How wide the editor's side panes were left, remembered across sessions.
///
/// Same shape as every other settings type here — a value struct over
/// `UserDefaults` with an explicit default — so there is one place a width is
/// stored and no second opinion about it.
///
/// Bounds matter more than they look. A pane dragged to nothing is
/// indistinguishable from a pane that failed to appear, and one dragged past
/// the window pushes the PICTURE out, which is the thing the whole layout
/// exists to protect. Clamping on load as well as on save means a value that
/// predates a bound — or was written by a build with different ones — comes
/// back usable instead of stranding the window in a state you cannot drag out
/// of.
public struct PaneWidths: Sendable, Equatable {
    /// The left rail's width. It carries BOTH indexes now — the markers list
    /// and, under it, the transcript — so one width governs both.
    public var markers: Double
    /// The transcript's HEIGHT within that rail, the markers list taking
    /// whatever is left.
    ///
    /// It was a width, when the transcript was a third column on the right.
    /// Stored under its own key rather than reusing that one: 340 was a
    /// perfectly ordinary width and is a perfectly ordinary height, so a
    /// reused key would silently reinterpret a stored value as a measurement
    /// of a different thing and look entirely plausible doing it.
    public var transcript: Double

    /// Below this a pane is a sliver, and its content is unreadable rather
    /// than merely small.
    /// Raised from 180 when the transcript joined this rail: a phrase with a
    /// time column beside it is unreadable much below this, and the rail is
    /// now the only place the transcript has.
    public static let minimumMarkers: Double = 260
    public static let minimumTranscript: Double = 140
    /// A pane wider than this is competing with the recording rather than
    /// supporting it.
    public static let maximumMarkers: Double = 460
    public static let maximumTranscript: Double = 560

    public static let defaultMarkers: Double = 260
    public static let defaultTranscript: Double = 300

    private static let markersKey = "com.impressiver.snitt.paneWidth.markers"
    /// `...paneHeight...`, not `...paneWidth...` — see `transcript` above for
    /// why the old key is not reused. The old one is REMOVED on save rather
    /// than left behind: a stale key that nothing reads is a value a later
    /// reader can find and believe.
    private static let transcriptKey = "com.impressiver.snitt.paneHeight.transcript"
    private static let retiredTranscriptWidthKey = "com.impressiver.snitt.paneWidth.transcript"

    public init(markers: Double = PaneWidths.defaultMarkers,
                transcript: Double = PaneWidths.defaultTranscript) {
        self.markers = Self.clampMarkers(markers)
        self.transcript = Self.clampTranscript(transcript)
    }

    public static func clampMarkers(_ value: Double) -> Double {
        min(max(value, minimumMarkers), maximumMarkers)
    }

    public static func clampTranscript(_ value: Double) -> Double {
        min(max(value, minimumTranscript), maximumTranscript)
    }

    public static func load(_ defaults: UserDefaults = .standard) -> PaneWidths {
        // `double(forKey:)` returns 0 for a key never written, which clamps up
        // to the minimum rather than to the default — a first run would get a
        // 180pt rail instead of the 260 it was designed at. Absence is checked
        // explicitly so "never set" and "set to something small" stay
        // different answers.
        PaneWidths(
            markers: defaults.object(forKey: markersKey) as? Double ?? defaultMarkers,
            transcript: defaults.object(forKey: transcriptKey) as? Double ?? defaultTranscript)
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(markers, forKey: Self.markersKey)
        defaults.set(transcript, forKey: Self.transcriptKey)
        defaults.removeObject(forKey: Self.retiredTranscriptWidthKey)
    }
}
