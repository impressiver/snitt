// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import Foundation

/// The click that counts you in (D102).
///
/// A system sound rather than an asset in the bundle. It is one click, it has
/// to be short and dry enough not to be recorded by the microphone it is
/// counting in, and shipping a sound file would mean licensing, an entry in
/// the third-party notices, and a review every time the bundle is audited —
/// for a tick.
///
/// Behind a type so the count-in can be tested without making a noise on a
/// test runner, which is the whole reason this is not two lines inline.
public struct CountInTick: Sendable {

    /// `Tink` is the shortest of the stock sounds and has almost no tail,
    /// which matters: the last beat lands immediately before the microphone
    /// opens, and a sound still ringing would be recorded into the take.
    public static let soundName = "Tink"

    /// Overridable so a test can count the ticks instead of hearing them.
    public var play: @Sendable () -> Void

    public init(play: @escaping @Sendable () -> Void = CountInTick.playSystemSound) {
        self.play = play
    }

    public static let playSystemSound: @Sendable () -> Void = {
        // Silently does nothing if the sound is missing rather than throwing:
        // a count-in that cannot click is a count-in you can still see, and
        // failing the take over a missing system sound would be absurd.
        NSSound(named: soundName)?.play()
    }
}
