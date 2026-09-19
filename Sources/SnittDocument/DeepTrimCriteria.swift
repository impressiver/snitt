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
    /// Also remove everything before the first input event and after the last,
    /// the way `snitt trim --auto-trim` does, instead of only the gaps between.
    ///
    /// Folded in here rather than left as a second call because the two
    /// questions have one answer on every recording an agent makes: "tidy this
    /// up" is a single intent that cost two verbs with two unrelated parameter
    /// vocabularies. Bookends are not findable from the picture and the audio
    /// (the setup at the head of a recording is usually its busiest, loudest
    /// part), so this reads the event log the way
    /// `EditDecisionList.autoTrimRange` does, and does nothing at all when
    /// there are no input events to bound the take.
    ///
    /// Off in this value and on in both frontends. The editor has a timeline
    /// and a pair of trim handles, so its deep-trim command keeps meaning
    /// exactly what it meant; a caller of the automation API has one call and
    /// cannot look at the result.
    public var trimBookends: Bool

    public init(minimumSpan: Double, audioSilenceFraction: Float,
                frameStillnessThreshold: Double, inputPadding: Double,
                subtitleReadingTime: Double, trimBookends: Bool = false) {
        self.minimumSpan = minimumSpan
        self.audioSilenceFraction = audioSilenceFraction
        self.frameStillnessThreshold = frameStillnessThreshold
        self.inputPadding = inputPadding
        self.subtitleReadingTime = subtitleReadingTime
        self.trimBookends = trimBookends
    }

    private enum CodingKeys: String, CodingKey {
        case minimumSpan, audioSilenceFraction, frameStillnessThreshold
        case inputPadding, subtitleReadingTime, trimBookends
    }

    /// Decoded by hand for one reason: a synthesized `init(from:)` ignores a
    /// property's default value and fails with `keyNotFound` on a payload
    /// written before that property existed. This value travels over the
    /// automation protocol, and a request that fails to DECODE never reaches
    /// §10's version refusal: it surfaces as `internal_error`, which is the
    /// one outcome that tells a caller nothing it can act on.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minimumSpan = try container.decode(Double.self, forKey: .minimumSpan)
        audioSilenceFraction = try container.decode(Float.self, forKey: .audioSilenceFraction)
        frameStillnessThreshold = try container.decode(Double.self, forKey: .frameStillnessThreshold)
        inputPadding = try container.decode(Double.self, forKey: .inputPadding)
        subtitleReadingTime = try container.decode(Double.self, forKey: .subtitleReadingTime)
        trimBookends = try container.decodeIfPresent(Bool.self, forKey: .trimBookends) ?? false
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
