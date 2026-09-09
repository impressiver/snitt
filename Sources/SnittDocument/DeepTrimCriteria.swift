// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

// Lives in SnittDocument, not beside `AutoDeepTrim` in SnittExport, for the
// same reason `CropRect` does: these are pure values that travel over the
// automation protocol, and `SnittAutomation` depends on this module and not on
// SnittExport. The detector that CONSUMES them needs AVFoundation and CoreGraphics
// and stays where it was.

/// How much footage survives an automatic trim (D57).
///
/// `conservative` / `default` / `aggressive` names the AXIS — how much is kept
/// — rather than the enforcement. An earlier draft said "strict", which reads
/// either as strict about preserving footage or strict about removing it:
/// opposite meanings in a feature whose entire job is deletion.
public enum DeepTrimPreset: String, Codable, Sendable, CaseIterable {
    case conservative
    case `default`
    case aggressive
}

/// What counts as dead air.
///  because it travels over the automation protocol: the CLI
/// resolves its `--preset` and per-criterion flags into one of these and sends
/// the RESULT, so the app has a single code path rather than one for presets
/// and another for flags.
/// `Codable` because it travels over the automation protocol: the CLI resolves
/// its `--preset` and per-criterion flags into one of these and sends the
/// RESULT, so the app has a single code path rather than one for presets and
/// another for flags.
public struct DeepTrimCriteria: Codable, Sendable, Equatable {
    /// Shortest span worth removing. Below this a cut costs more attention
    /// than the seconds it saves.
    public var minimumSpan: Double
    /// Audio at or below this fraction of the track's own typical loud level
    /// is background noise.
    ///
    /// Relative, and measured against a high percentile rather than the peak,
    /// for the reason D73 records: one clipped instant — a cough, a chime,
    /// music bleeding in from speakers — sets the floor above all the speech
    /// if the maximum is the reference.
    public var audioSilenceFraction: Float
    /// Frame-to-frame difference at or below this is a still picture.
    public var frameStillnessThreshold: Double
    /// Seconds kept either side of a click, keystroke or marker.
    public var inputPadding: Double
    /// Seconds a spoken word stays "owed" after it finishes.
    ///
    /// D44 missed this and D57 added it: a caption still on screen is not dead
    /// air just because nothing moved while it was being read.
    public var subtitleReadingTime: Double

    public init(minimumSpan: Double, audioSilenceFraction: Float,
                frameStillnessThreshold: Double, inputPadding: Double,
                subtitleReadingTime: Double) {
        self.minimumSpan = minimumSpan
        self.audioSilenceFraction = audioSilenceFraction
        self.frameStillnessThreshold = frameStillnessThreshold
        self.inputPadding = inputPadding
        self.subtitleReadingTime = subtitleReadingTime
    }

    public static func preset(_ preset: DeepTrimPreset) -> DeepTrimCriteria {
        switch preset {
        case .conservative:
            DeepTrimCriteria(minimumSpan: 3.0, audioSilenceFraction: 0.04,
                             frameStillnessThreshold: 0.002, inputPadding: 1.5,
                             subtitleReadingTime: 1.5)
        case .default:
            DeepTrimCriteria(minimumSpan: 1.5, audioSilenceFraction: 0.08,
                             frameStillnessThreshold: 0.006, inputPadding: 0.75,
                             subtitleReadingTime: 0.8)
        case .aggressive:
            DeepTrimCriteria(minimumSpan: 0.8, audioSilenceFraction: 0.16,
                             frameStillnessThreshold: 0.02, inputPadding: 0.3,
                             subtitleReadingTime: 0.3)
        }
    }
}
