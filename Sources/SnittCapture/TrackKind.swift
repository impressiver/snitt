// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import ScreenCaptureKit

/// The three tracks a Snitt recording carries. Audio is kept in two discrete
/// tracks so either can be muted independently later (spec section 4.2).
public enum TrackKind: String, CaseIterable, Sendable {
    case video
    case systemAudio
    case microphone

    /// Maps a ScreenCaptureKit output type onto a track.
    ///
    /// All three arrive on one `SCStream` against one clock, which is why
    /// macOS 15 is the minimum (spec section 4.6).
    public init?(_ outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:     self = .video
        case .audio:      self = .systemAudio
        case .microphone: self = .microphone
        @unknown default: return nil
        }
    }
}
