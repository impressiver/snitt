// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// What the recording HUD shows for a given state.
public struct RecordingHUDPresentation: Equatable, Sendable {
    /// Whether the panel is on screen at all.
    public var isVisible: Bool
    /// Footage so far, or nil when there is no meaningful number to show.
    public var clock: String?
    /// The word beside the clock. Nil while plainly recording — "Recording"
    /// there would be noise next to a live red dot and a running timer.
    public var statusWord: String?
    /// Drives the *shape* of the indicator, not just its colour: a hollow ring
    /// while paused, a filled dot while recording. §5.3's obligation is that a
    /// person can tell at a glance, and a glance that depends on separating
    /// red from grey is not one everybody can take.
    public var isPaused: Bool
    public var canMark: Bool
    public var canTogglePause: Bool
    public var canStop: Bool
    /// Posted to the accessibility system on entering this state.
    ///
    /// The HUD never becomes key (§4.11), so it can never announce itself by
    /// taking focus — a VoiceOver user would otherwise have no way to learn
    /// that a recording paused. Empty means nothing worth saying.
    public var announcement: String
}

/// The recording HUD's rules, with no panel attached.
///
/// Every decision worth getting right here — which controls a state permits,
/// what the clock reads, what a screen reader is told — is a function of
/// `RecordingState` and the current time. None of it needs an `NSPanel`, and
/// an `NSPanel` is exactly the thing a test cannot easily interrogate, so none
/// of it lives in one.
public enum RecordingHUDModel {

    public static func presentation(for state: RecordingState,
                                    now: Date) -> RecordingHUDPresentation {
        switch state {
        case .idle:
            // Not merely empty — absent. §4.11 keeps recording free of
            // windows, and a HUD lingering over an idle desktop is a window
            // that outstayed the thing it was reporting on.
            return RecordingHUDPresentation(
                isVisible: false, clock: nil, statusWord: nil, isPaused: false,
                canMark: false, canTogglePause: false, canStop: false,
                announcement: "")

        case .recording:
            return RecordingHUDPresentation(
                isVisible: true,
                clock: RecordingState.clock(state.footageSeconds(at: now)),
                statusWord: nil, isPaused: false,
                canMark: true, canTogglePause: true, canStop: true,
                announcement: "Recording")

        case .paused:
            return RecordingHUDPresentation(
                isVisible: true,
                clock: RecordingState.clock(state.footageSeconds(at: now)),
                statusWord: "Paused", isPaused: true,
                // Marking a paused recording is allowed and lands at the
                // pause point — `setPausedForAgent` already marks as part of
                // pausing, so a mark here is the same act done deliberately.
                canMark: true, canTogglePause: true, canStop: true,
                announcement: "Recording paused")

        case .stopping:
            // No clock: the number stopped meaning anything the moment the
            // recording did, and a frozen timer reads as a hung app. Every
            // control is off because the answer to all of them is now "too
            // late" — a second Stop during finalisation is the double-stop
            // this project has already fixed once.
            return RecordingHUDPresentation(
                isVisible: true, clock: nil, statusWord: "Saving…", isPaused: false,
                canMark: false, canTogglePause: false, canStop: false,
                announcement: "Saving the recording")
        }
    }

    /// How a control names itself, including the key that reaches it without
    /// the pointer.
    ///
    /// A panel that never becomes key cannot be tabbed to, so a control whose
    /// only route is a click is unreachable for a keyboard or VoiceOver user.
    /// Two of the three already have keys — the marker hotkey and the record
    /// hotkey, which toggles and therefore stops — and this reads the user's
    /// ACTUAL bindings rather than naming a default they may have changed. A
    /// label claiming a shortcut that does not work is worse than one that
    /// claims nothing.
    ///
    /// `pause` passes nil, because there is no pause hotkey to name yet. It is
    /// the one control here that is pointer-only, and saying so honestly is
    /// what keeps the gap visible instead of papered over.
    public static func controlLabel(_ verb: String, shortcut: String?) -> String {
        guard let shortcut, !shortcut.isEmpty else { return verb }
        return "\(verb), \(shortcut)"
    }
}
