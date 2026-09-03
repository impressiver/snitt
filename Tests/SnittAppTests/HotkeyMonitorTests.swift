import Testing
import Foundation
@testable import SnittApp

@Test("The default combination is option-command-5")
func defaultCombinationIsOptCmd5() {
    let c = HotkeyCombination.defaultCombination
    // kVK_ANSI_5 is 0x17.
    #expect(c.keyCode == 0x17)
    #expect(c.modifiers != 0, "a bare keycode with no modifiers would hijack the key")
}

@Test("Combinations compare by keycode and modifiers together")
func combinationsCompareOnBothFields() {
    let a = HotkeyCombination(keyCode: 0x17, modifiers: 1)
    let b = HotkeyCombination(keyCode: 0x17, modifiers: 2)
    let c = HotkeyCombination(keyCode: 0x17, modifiers: 1)
    #expect(a != b)
    #expect(a == c)
}

@Test("A monitor registers under its own instance id, not a constant")
func registrationUsesTheInstanceID() {
    // The original defect was a hard-coded id in start(). A correct allocator
    // did not prevent it, so assert the registration itself.
    let first = HotkeyMonitor(combination: .defaultCombination) {}
    let second = HotkeyMonitor(combination: .markerCombination) {}

    #expect(first.registrationID.id == first.hotKeyID)
    #expect(second.registrationID.id == second.hotKeyID)
    #expect(first.registrationID.id != second.registrationID.id,
            "two monitors registering the same id is half of the cross-firing bug")
}

@Test("The marker combination differs from the record combination")
func markerCombinationIsDistinct() {
    #expect(HotkeyCombination.markerCombination != HotkeyCombination.defaultCombination)
}

@Test("A monitor only fires for its own hotkey id")
func monitorIgnoresOtherHotkeys() {
    var fired = 0
    let monitor = HotkeyMonitor(combination: .markerCombination) { fired += 1 }
    monitor.handle(hotKeyID: monitor.hotKeyID)
    #expect(fired == 1)
    monitor.handle(hotKeyID: monitor.hotKeyID &+ 1)
    #expect(fired == 1, "a monitor must ignore a hotkey it did not register")
}

// Both tests below register the real ⌥⌘5 combination with the window server.
// Grouped in a serialized suite so they cannot run concurrently and collide
// on that single, real, OS-level resource (swift-testing parallelizes free
// functions across the whole target by default).
@Suite(.serialized)
struct HotkeyRegistrationTests {
    @Test("Registering the same monitor twice is refused rather than duplicating")
    func doubleStartIsSafe() throws {
        let monitor = HotkeyMonitor(combination: .defaultCombination) {}
        try monitor.start()
        defer { monitor.stop() }
        // A second start must not register a second handler for the same
        // combination — that would fire the callback twice per press.
        try monitor.start()
        #expect(monitor.isRegistered)
    }

    @Test("A failed registration leaves nothing installed, so a retry is clean")
    func failedStartLeavesNoResidue() throws {
        // Hold the combination so the second monitor's registration must fail.
        let holder = HotkeyMonitor(combination: .defaultCombination) {}
        try holder.start()
        defer { holder.stop() }

        let contender = HotkeyMonitor(combination: .defaultCombination) {}
        #expect(throws: (any Error).self) { try contender.start() }
        #expect(contender.isRegistered == false)

        // The contender must have torn its handler back down, so releasing it is safe
        // and a later start() after the holder frees the combination works cleanly.
        holder.stop()
        try contender.start()
        #expect(contender.isRegistered == true)
        contender.stop()
    }
}
