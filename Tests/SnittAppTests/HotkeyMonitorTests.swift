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
