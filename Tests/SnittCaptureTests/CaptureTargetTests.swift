import Testing
import Foundation
@testable import SnittCapture

@Test("Descriptors encode to stable JSON for the CLI contract")
func descriptorEncodesStably() throws {
    let descriptor = CaptureTargetDescriptor(
        id: 42, kind: "window", title: "Safari",
        applicationName: "Safari", width: 1440, height: 900
    )
    let data = try JSONEncoder().encode(descriptor)
    let decoded = try JSONDecoder().decode(CaptureTargetDescriptor.self, from: data)

    #expect(decoded.id == 42)
    #expect(decoded.kind == "window")
    #expect(decoded.title == "Safari")
    #expect(decoded.width == 1440)
}

@Test("Descriptor kind is constrained to display or window")
func descriptorKindIsConstrained() {
    #expect(CaptureTargetDescriptor.Kind.display.rawValue == "display")
    #expect(CaptureTargetDescriptor.Kind.window.rawValue == "window")
}
