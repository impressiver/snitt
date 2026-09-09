// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittCapture

@Test("Descriptors encode to stable JSON for the CLI contract")
func descriptorEncodesStably() throws {
    let descriptor = CaptureTargetDescriptor(
        id: 42, kind: "window", title: "Safari",
        applicationName: "Safari", width: 1440, height: 900,
        processID: 4242
    )
    let data = try JSONEncoder().encode(descriptor)
    let decoded = try JSONDecoder().decode(CaptureTargetDescriptor.self, from: data)

    #expect(decoded.id == 42)
    #expect(decoded.kind == "window")
    #expect(decoded.title == "Safari")
    #expect(decoded.width == 1440)
    #expect(decoded.processID == 4242,
            "the pid crosses the wire too — it is what auto-focus acts on")
}

@Test("Descriptor kind is constrained to display or window")
func descriptorKindIsConstrained() {
    #expect(CaptureTargetDescriptor.Kind.display.rawValue == "display")
    #expect(CaptureTargetDescriptor.Kind.window.rawValue == "window")
}
