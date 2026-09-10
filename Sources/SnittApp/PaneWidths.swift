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
    public var markers: Double
    public var transcript: Double

    /// Below this a pane is a sliver, and its content is unreadable rather
    /// than merely small.
    public static let minimumMarkers: Double = 180
    public static let minimumTranscript: Double = 260
    /// A pane wider than this is competing with the recording rather than
    /// supporting it.
    public static let maximumMarkers: Double = 460
    public static let maximumTranscript: Double = 640

    public static let defaultMarkers: Double = 260
    public static let defaultTranscript: Double = 340

    private static let markersKey = "com.impressiver.snitt.paneWidth.markers"
    private static let transcriptKey = "com.impressiver.snitt.paneWidth.transcript"

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
    }
}
