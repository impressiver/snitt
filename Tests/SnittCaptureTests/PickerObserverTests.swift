import Testing
import Foundation
@testable import SnittCapture

@Test("The observer delivers exactly one outcome even if signalled twice")
func observerDeliversOnce() async throws {
    let box = PickerOutcomeBox()

    let first = await box.deliver(.failure(.cancelled))
    let second = await box.deliver(.failure(.unavailable))

    #expect(first == true, "the first outcome must be accepted")
    #expect(second == false,
            "a second outcome must be refused — resuming a continuation twice traps")
}

@Test("The observer reports whether it has already completed")
func observerTracksCompletion() async {
    let box = PickerOutcomeBox()
    #expect(await box.hasCompleted == false)
    _ = await box.deliver(.failure(.cancelled))
    #expect(await box.hasCompleted == true)
}
