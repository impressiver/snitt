// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittAutomation

/// Whether an OPTIONAL field can be added to an `AutomationResponse` case
/// without breaking a client built before it existed.
///
/// This needed settling empirically rather than by reasoning about Swift's
/// synthesis rules, and the usual shortcut is not available: `.stopped`'s doc
/// comment justifies its own additive `health` field on the grounds that "v2
/// has never shipped ... there is no released v2 client to stay compatible
/// with". That was true when written and is **false now** — v2 ships in every
/// release from 0.2.0 onward, so the next additive change cannot borrow that
/// reasoning and has to prove the compatibility it assumes.
@Suite
struct ResponseWireCompatibilityTests {

    /// The shape an older app wrote, before `.screenshotTaken` carried an image.
    private static let oldScreenshotPayload =
        #"{"screenshotTaken":{"path":"/tmp/x.snitt/shot-1.png","timeSeconds":1.5}}"#

    @Test("A payload written before the field existed still decodes")
    func oldPayloadDecodes() throws {
        // The forward direction: a NEW client reading an OLD app's response.
        // If synthesized Codable required the key rather than treating the
        // Optional as absent-means-nil, this throws `keyNotFound` and every
        // agent talking to a not-yet-updated app breaks on screenshot.
        let decoded = try JSONDecoder().decode(
            AutomationResponse.self,
            from: Data(Self.oldScreenshotPayload.utf8))
        guard case .screenshotTaken(let path, let time, _) = decoded else {
            Issue.record("did not decode as screenshotTaken: \(decoded)"); return
        }
        #expect(path == "/tmp/x.snitt/shot-1.png")
        #expect(time == 1.5)
    }

    @Test("A payload carrying an unknown extra field still decodes")
    func unknownFieldIsIgnored() throws {
        // The reverse direction: an OLD client reading a NEW app's response.
        // Keyed containers ignore keys they have no property for, so this
        // should pass; asserting it means a future move to an unkeyed or
        // positional encoding cannot silently break older clients.
        let future = #"{"screenshotTaken":{"path":"/tmp/x.png","timeSeconds":2,"somethingNew":"x"}}"#
        let decoded = try JSONDecoder().decode(
            AutomationResponse.self, from: Data(future.utf8))
        guard case .screenshotTaken(_, let time, _) = decoded else {
            Issue.record("did not decode as screenshotTaken: \(decoded)"); return
        }
        #expect(time == 2)
    }

    @Test("A round trip preserves the case and its values")
    func roundTrips() throws {
        let original = AutomationResponse.screenshotTaken(path: "/tmp/x.png", timeSeconds: 3)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AutomationResponse.self, from: data)
        #expect(decoded == original)
    }
}
