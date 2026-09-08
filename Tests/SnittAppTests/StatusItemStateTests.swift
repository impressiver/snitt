import Testing
import Foundation
@testable import SnittApp

@Test("Idle shows the record affordance and no stop control")
func idlePresentation() {
    let p = StatusItemController.presentation(for: .idle, now: Date())
    #expect(p.isStopEnabled == false)
    #expect(p.symbolName == "record.circle")
}

@Test("Recording shows elapsed time and an enabled stop control")
func recordingPresentation() {
    let started = Date(timeIntervalSince1970: 1_000)
    let now = Date(timeIntervalSince1970: 1_065)
    let p = StatusItemController.presentation(for: .recording(startedAt: started),
                                              now: now)
    #expect(p.isStopEnabled == true)
    #expect(p.title == "1:05", "elapsed time must be visible while recording")
    #expect(p.symbolName == "stop.circle.fill")
}

@Test("Elapsed time pads seconds below ten")
func elapsedPadsSeconds() {
    let started = Date(timeIntervalSince1970: 0)
    let p = StatusItemController.presentation(for: .recording(startedAt: started),
                                              now: Date(timeIntervalSince1970: 63))
    #expect(p.title == "1:03")
}

@Test("Stopping disables the stop control so it cannot be pressed twice")
func stoppingDisablesStop() {
    let p = StatusItemController.presentation(for: .stopping, now: Date())
    #expect(p.isStopEnabled == false,
            "a second stop press during finalization must be impossible")
}

// MARK: - Paused (M5e, D53)

/// §5.3 requires a visible indicator for the whole duration of a recording.
/// D53 adds that a PAUSED recording must be distinguishable, because a human at
/// the machine is the only fallback when an agent forgets to resume — and an
/// indicator identical to the recording one gives them nothing to notice.
@Test("A paused recording looks different from a running one")
func pausedLooksDifferent() {
    let start = Date()
    let now = start.addingTimeInterval(90)
    let running = StatusItemController.presentation(
        for: .recording(startedAt: start), now: now)
    let paused = StatusItemController.presentation(
        for: .paused(startedAt: start, pausedSeconds: 30), now: now)

    #expect(running.symbolName != paused.symbolName, "same glyph for both states")
    #expect(paused.title.contains("Paused"), "the title does not say it is paused")
}

@Test("The paused counter shows footage, not wall time")
func pausedCounterShowsFootage() {
    // A counter that kept climbing while nothing is filmed says the recording
    // is fine when it is frozen — the exact misreading D53 is about. 90s
    // elapsed with 30s paused is 60s of footage.
    let start = Date()
    let paused = StatusItemController.presentation(
        for: .paused(startedAt: start, pausedSeconds: 30),
        now: start.addingTimeInterval(90))
    #expect(paused.title.contains("1:00"), "expected 1:00 of footage, got \(paused.title)")
}

@Test("Stop stays available while paused")
func stopWorksWhilePaused() {
    // §5.3's kill switch is not optional in any state that holds the camera. A
    // paused session still owns the capture as far as the OS and the user are
    // concerned, and being unable to stop it would be worse than not pausing.
    let paused = StatusItemController.presentation(
        for: .paused(startedAt: Date(), pausedSeconds: 0), now: Date())
    #expect(paused.isStopEnabled)
}
