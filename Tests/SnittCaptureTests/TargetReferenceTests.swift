import Testing
import Foundation
@testable import SnittCapture

@Test("A window reference stores bundle id and title hint, never a window id")
func windowReferenceShape() throws {
    let ref = TargetReference.window(bundleIdentifier: "com.apple.Safari",
                                     titleHint: "Release Notes")
    #expect(ref.kind == .window)
    #expect(ref.bundleIdentifier == "com.apple.Safari")
    #expect(ref.titleHint == "Release Notes")
    #expect(ref.displayID == nil)
}

@Test("A display reference stores the display id and no bundle id")
func displayReferenceShape() throws {
    let ref = TargetReference.display(id: 7)
    #expect(ref.kind == .display)
    #expect(ref.displayID == 7)
    #expect(ref.bundleIdentifier == nil)
}

@Test("References round-trip through JSON")
func referenceRoundTrips() throws {
    let ref = TargetReference.window(bundleIdentifier: "com.apple.Safari",
                                     titleHint: nil)
    let data = try JSONEncoder().encode(ref)
    let back = try JSONDecoder().decode(TargetReference.self, from: data)
    #expect(back == ref)
}
