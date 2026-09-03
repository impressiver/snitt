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
