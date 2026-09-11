// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittApp

/// The recording HUD's rules, tested without a panel.
@Suite
struct RecordingHUDModelTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private func now(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    @Test("Idle hides the HUD rather than showing an empty one")
    func idleIsAbsent() {
        // §4.11 keeps recording free of windows. A HUD that stays put over an
        // idle desktop is a window that outlived what it was reporting on —
        // and an implementation that only greys the controls out would leave
        // it there.
        let p = RecordingHUDModel.presentation(for: .idle, now: now(0))
        #expect(p.isVisible == false)
        #expect(p.canStop == false)
    }

    @Test("Recording shows a running clock and every control live")
    func recordingIsLive() {
        let p = RecordingHUDModel.presentation(for: .recording(startedAt: start), now: now(42))
        #expect(p.isVisible)
        #expect(p.clock == "0:42")
        #expect(p.isPaused == false)
        #expect(p.canMark && p.canTogglePause && p.canStop)
        // No "Recording" word: the live dot and the running timer already say
        // it, and a label repeating them is noise in a lightweight HUD.
        #expect(p.statusWord == nil)
    }

    @Test("Paused counts FOOTAGE, not wall clock")
    func pausedCountsFootage() {
        // The rule that matters, and the one a reimplementation gets wrong:
        // 100 seconds after starting, having been paused for 40, the counter
        // reads 1:00 — not 1:40. A clock that kept climbing while nothing was
        // filmed would say the recording is fine when it is frozen.
        let state = RecordingState.paused(startedAt: start, pausedSeconds: 40)
        let p = RecordingHUDModel.presentation(for: state, now: now(100))
        #expect(p.clock == "1:00")
        #expect(p.statusWord == "Paused")
        #expect(p.isPaused)
    }

    @Test("The HUD and the menu bar never disagree about elapsed time")
    func hudAgreesWithTheMenuBar() {
        // Two surfaces showing one number. This is the assertion that keeps
        // them one clock rather than two wearing the same name — it fails the
        // moment either grows its own arithmetic.
        for state in [RecordingState.recording(startedAt: start),
                      .paused(startedAt: start, pausedSeconds: 17)] {
            let hud = RecordingHUDModel.presentation(for: state, now: now(95))
            let bar = StatusItemController.presentation(for: state, now: now(95))
            let hudClock = try! #require(hud.clock)
            #expect(bar.title.contains(hudClock),
                    "menu bar says \(bar.title), HUD says \(hudClock)")
        }
    }

    @Test("Pausing changes the indicator's SHAPE, not only its colour")
    func pauseIsNotColourAlone() {
        // Someone who cannot separate red from grey still has to be able to
        // tell a paused recording from a running one. `isPaused` is what
        // drives a hollow ring versus a filled dot; without it the states are
        // distinguishable by hue alone.
        let recording = RecordingHUDModel.presentation(for: .recording(startedAt: start), now: now(1))
        let paused = RecordingHUDModel.presentation(
            for: .paused(startedAt: start, pausedSeconds: 0), now: now(1))
        #expect(recording.isPaused != paused.isPaused)
    }

    @Test("Saving disables every control and drops the clock")
    func stoppingIsInert() {
        // A second Stop during finalisation is the double-stop this project
        // has already fixed once. A frozen timer reads as a hung app, so the
        // number goes rather than sticking.
        let p = RecordingHUDModel.presentation(for: .stopping, now: now(10))
        #expect(p.isVisible)
        #expect(p.statusWord == "Saving…")
        #expect(p.clock == nil)
        #expect(!p.canStop && !p.canMark && !p.canTogglePause)
    }

    @Test("Every visible state announces itself, because the HUD cannot take focus")
    func statesAnnounceThemselves() {
        // The HUD never becomes key (§4.11), so it can never announce itself
        // by being focused. Without a posted announcement a VoiceOver user has
        // no way to learn that a recording paused — the panel is simply
        // unreachable. Empty strings here are a silent HUD.
        for state in [RecordingState.recording(startedAt: start),
                      .paused(startedAt: start, pausedSeconds: 0),
                      .stopping] {
            let p = RecordingHUDModel.presentation(for: state, now: now(1))
            #expect(!p.announcement.isEmpty, "\(state) says nothing to VoiceOver")
        }
        #expect(RecordingHUDModel.presentation(for: .idle, now: now(1)).announcement.isEmpty)
    }

    @Test("Paused and recording do not announce the same thing")
    func announcementsDistinguishTheStates() {
        // An announcement that said "Recording" for both would be worse than
        // none: it asserts the opposite of what happened.
        let recording = RecordingHUDModel.presentation(for: .recording(startedAt: start), now: now(1))
        let paused = RecordingHUDModel.presentation(
            for: .paused(startedAt: start, pausedSeconds: 0), now: now(1))
        #expect(recording.announcement != paused.announcement)
    }

    @Test("A clock never runs backwards on a clock skew")
    func negativeElapsedIsClamped() {
        // `now` earlier than `startedAt` is reachable — NTP steps the clock,
        // and a recording started seconds before one lands here.
        let p = RecordingHUDModel.presentation(for: .recording(startedAt: start), now: now(-30))
        #expect(p.clock == "0:00")
    }
}

// What the HUD animates, and when (rev 5, W4).
//
// W4's paint and behaviours were never scheduled — the spec's five-PR table
// omitted W4 from every group — so the HUD shipped with three identical
// system buttons and no motion at all. These pin the rules rather than the
// animations: "is a CAAnimation attached" asserts the mechanism, and the
// interesting part is WHEN.
@Suite
struct RecordingHUDMotionTests {

    @Test("The dot breathes only while actually recording")
    func breathesWhileRecording() {
        #expect(RecordingHUDMotion.dotBreathes(isRecording: true, isPaused: false,
                                               reduceMotion: false))
    }

    @Test("A paused HUD is still")
    func pausedDoesNotBreathe() {
        // A pulsing dot beside the word "Paused" says two different things at
        // once, and §5.3's obligation is that a glance tells you which.
        #expect(!RecordingHUDMotion.dotBreathes(isRecording: true, isPaused: true,
                                                reduceMotion: false))
    }

    @Test("Reduced motion is a setting, not a preference to weigh")
    func reducedMotionWins() {
        #expect(!RecordingHUDMotion.dotBreathes(isRecording: true, isPaused: false,
                                                reduceMotion: true))
    }

    @Test("A HUD left alone while recording fades")
    func idleRecordingFades() {
        // At full strength through a ten-minute recording it stops being
        // lightweight, which is the one thing §4.11 asks this panel to be.
        #expect(RecordingHUDMotion.alpha(isRecording: true, isPaused: false,
                                         pointerNear: false,
                                         secondsIdle: RecordingHUDMotion.idleAfterSeconds)
                == RecordingHUDMotion.idleAlpha)
    }

    @Test("The pointer coming near brings it straight back")
    func pointerRestoresIt() {
        #expect(RecordingHUDMotion.alpha(isRecording: true, isPaused: false,
                                         pointerNear: true, secondsIdle: 600) == 1)
    }

    @Test("A paused HUD never fades — it is reporting an abnormal state")
    func pausedNeverFades() {
        // The sequence that matters: pausing DURING the fade must restore it.
        // A paused recording is the state you are most likely to be looking
        // for, and a faded panel is the one you cannot find.
        #expect(RecordingHUDMotion.alpha(isRecording: true, isPaused: true,
                                         pointerNear: false, secondsIdle: 600) == 1)
    }

    @Test("It does not fade before it has been left alone")
    func fadesOnlyAfterTheDelay() {
        #expect(RecordingHUDMotion.alpha(isRecording: true, isPaused: false,
                                         pointerNear: false,
                                         secondsIdle: RecordingHUDMotion.idleAfterSeconds - 0.1)
                == 1)
    }

    @MainActor
    @Test("Mark prints the user's real key, or no key at all")
    func markTitleUsesTheRealBinding() {
        // PR #66's rule, on the one control this design emphasises: a
        // hardcoded shortcut that does nothing is worse than none. Pause has
        // no `HotkeyAction` case, so it names none — and Mark must behave the
        // same way when nothing is bound.
        #expect(RecordingHUDView.markTitle(shortcut: "⌥⌘M").string.contains("⌥⌘M"))
        #expect(RecordingHUDView.markTitle(shortcut: nil).string == "Mark")
        #expect(RecordingHUDView.markTitle(shortcut: "").string == "Mark")
    }
}
