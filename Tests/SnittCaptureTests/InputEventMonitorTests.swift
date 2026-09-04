import Testing
import CoreGraphics
@testable import SnittCapture
import SnittDocument

@Test("Key and mouse events map to the kinds the log stores")
func eventTypesMapToKinds() {
    #expect(InputEventMonitor.kind(for: .keyDown) == .keystroke)
    #expect(InputEventMonitor.kind(for: .leftMouseDown) == .click)
    #expect(InputEventMonitor.kind(for: .rightMouseDown) == .click)
}

@Test("Key UP is not logged — one keystroke must not count as two")
func keyUpIsIgnored() {
    // Down and up both arrive. Logging both would double every keystroke,
    // which matters because M3c's --auto-trim reasons about event density.
    #expect(InputEventMonitor.kind(for: .keyUp) == nil)
    #expect(InputEventMonitor.kind(for: .leftMouseUp) == nil)
}

@Test("Tap-disabled notifications are not logged as input")
func tapDisabledIsNotAnEvent() {
    // macOS sends these THROUGH the tap callback. Treating them as input
    // would put phantom events in the log at the moment the tap broke.
    #expect(InputEventMonitor.kind(for: .tapDisabledByTimeout) == nil)
    #expect(InputEventMonitor.kind(for: .tapDisabledByUserInput) == nil)
}

@Test("The event mask covers exactly the types that map to a kind")
func maskMatchesTheMappedTypes() {
    // A mask that requested types we then drop would wake the callback for
    // nothing on every keypress; a mask missing a mapped type would silently
    // never log it.
    let mapped: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown]
    for type in mapped {
        #expect(InputEventMonitor.eventMask & (1 << type.rawValue) != 0,
                "\(type) maps to a kind but is not in the mask")
    }
    let unmapped: [CGEventType] = [.keyUp, .leftMouseUp, .mouseMoved]
    for type in unmapped {
        #expect(InputEventMonitor.eventMask & (1 << type.rawValue) == 0,
                "\(type) is in the mask but maps to no kind")
    }
}
