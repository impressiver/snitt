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

@Test("An outcome arriving before the continuation is armed is not lost")
func earlyOutcomeIsHeldUntilArmed() async throws {
    let box = PickerOutcomeBox()
    // Deliver BEFORE anything is armed — the old design dropped this silently.
    let accepted = await box.deliver(.failure(.cancelled))
    #expect(accepted == true)
    #expect(await box.hasCompleted == true)

    // Arming afterwards must resume with the held outcome rather than hang.
    await #expect(throws: TargetResolutionError.cancelled) {
        try await withCheckedThrowingContinuation { continuation in
            Task { await box.arm(continuation) }
        }
    }
}
