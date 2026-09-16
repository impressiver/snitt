// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation

/// The transport, while an over-dub is being recorded (D102).
///
/// Two buttons and four states, which is more than it sounds: record and
/// play/pause each mean something different depending on what is already
/// happening, and "pause" has to mean *pause the take* rather than *abandon
/// it* — you stop to think mid-sentence and carry on.
///
/// Pure, and separate from anything that plays or records, because the states
/// are where the behaviour lives and none of it is observable from outside a
/// running app. A state machine expressed as scattered `if isRecording` checks
/// across a view and a controller is one nobody can assert against, and that
/// is how "the + does nothing" shipped.
public enum OverdubTransport {

    /// How many beats the count-in lasts.
    ///
    /// Three is the convention everywhere a musician has ever been counted in,
    /// and the number matters less than its being enough to draw breath. It is
    /// here rather than inline so the tick and the display cannot disagree
    /// about how long they are counting.
    public static let countInBeats = 3

    public enum State: Equatable, Sendable {
        /// Not recording. Play/pause does what it always does.
        case idle
        /// Counting in. Nothing is being recorded yet and the playhead has not
        /// moved — a count-in that played the video would make the first beat
        /// land on footage the take is not over.
        case countingIn(remaining: Int)
        /// Recording, playhead running.
        case recording
        /// **Still recording, playhead stopped.** The take is open and the
        /// button stays lit; pressing play carries on into the same take.
        /// Abandoning a take because you paused to think would make pause
        /// unusable during the one operation it is most needed for.
        case armedButPaused

        /// Whether the record button should read as active.
        ///
        /// True through the count-in as well: pressing record has already
        /// committed to a take, and a button that lit only once the count
        /// finished would leave the three most uncertain seconds looking like
        /// nothing had happened.
        public var isRecordActive: Bool { self != .idle }

        /// Whether the microphone is actually being written to right now.
        ///
        /// NOT the same as `isRecordActive`, and that difference is a bug this
        /// shipped with. A paused take is still open — the button is lit and
        /// the file is waiting — but nothing is being captured, so anything
        /// that samples the input has to ask THIS. Guarding the level meter on
        /// "is a take open" kept it metering through a pause: the lane went on
        /// growing, drawing a take that was getting longer while the recorder
        /// was stopped.
        public var isCapturingAudio: Bool { self == .recording }
    }

    public enum Action: Equatable, Sendable {
        case tapRecord
        case tapPlayPause
        /// One beat of the count-in.
        case countInBeat
    }

    /// What the caller should DO, alongside the new state.
    ///
    /// Effects are returned rather than performed so the machine stays pure —
    /// and so a test can assert that stopping a take also stops playback,
    /// which is a rule about the pair and not about either one.
    public struct Step: Equatable, Sendable {
        public var state: State
        public var startRecording = false
        public var stopRecording = false
        /// Suspends the take without ending it.
        public var pauseRecording = false
        public var resumeRecording = false
        public var play = false
        public var pause = false
        /// Audible click for one beat of the count-in.
        public var playTick = false

        public init(state: State) { self.state = state }
    }

    public static func next(_ state: State, _ action: Action) -> Step {
        switch (state, action) {

        // MARK: Starting

        case (.idle, .tapRecord):
            // The count-in begins immediately and audibly. Nothing records and
            // nothing plays yet.
            var step = Step(state: .countingIn(remaining: countInBeats))
            step.playTick = true
            return step

        case (.countingIn(let remaining), .countInBeat) where remaining > 1:
            var step = Step(state: .countingIn(remaining: remaining - 1))
            step.playTick = true
            return step

        case (.countingIn, .countInBeat):
            // The last beat starts the take AND the playback together: a take
            // that began a frame before the picture moved would have its first
            // word over the wrong footage.
            var step = Step(state: .recording)
            step.startRecording = true
            step.play = true
            return step

        // MARK: Stopping

        case (.recording, .tapRecord), (.armedButPaused, .tapRecord):
            // Record STOPS the take and pauses playback, rather than leaving
            // the video running: the thing you do next is listen to what you
            // just recorded, and that starts from a standstill.
            var step = Step(state: .idle)
            step.stopRecording = true
            step.pause = true
            return step

        case (.countingIn, .tapRecord):
            // Pressing record during the count-in cancels it. Nothing was
            // recorded, so there is nothing to keep and nothing to stop.
            return Step(state: .idle)

        case (.countingIn, .tapPlayPause):
            // Pressing PLAY during the count-in is somebody who has changed
            // their mind and wants to watch. It abandons the take and plays,
            // because the alternative — swallowing the press to protect a take
            // that has recorded nothing — makes the transport feel stuck.
            var step = Step(state: .idle)
            step.play = true
            return step

        // MARK: Pausing, without ending the take

        case (.recording, .tapPlayPause):
            var step = Step(state: .armedButPaused)
            step.pauseRecording = true
            step.pause = true
            return step

        case (.armedButPaused, .tapPlayPause):
            var step = Step(state: .recording)
            step.resumeRecording = true
            step.play = true
            return step

        // MARK: Everything else

        case (.idle, .tapPlayPause):
            // Ordinary playback. The caller decides which way to toggle; this
            // machine has no opinion about a transport that is not recording.
            return Step(state: .idle)

        case (.idle, .countInBeat), (.recording, .countInBeat),
             (.armedButPaused, .countInBeat):
            // A beat that arrives after the count-in ended, because a timer
            // fired once more before it was cancelled. Ignored rather than
            // treated as a state change — a stray tick must not restart
            // anything.
            return Step(state: state)
        }
    }
}
