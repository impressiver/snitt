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
        guard case .screenshotTaken(let path, let time, _, let marked) = decoded else {
            Issue.record("did not decode as screenshotTaken: \(decoded)"); return
        }
        #expect(path == "/tmp/x.snitt/shot-1.png")
        #expect(time == 1.5)
        // An app that predates `marked` made a marker for every screenshot, so
        // the absent key has to read as `true`. Defaulting it to `false` would
        // have a new client tell its user "no marker was placed" about an app
        // that placed one — a confident wrong answer, which is the failure
        // mode this whole suite exists to catch.
        #expect(marked == nil, "the key must be absent, not defaulted, or older apps fail to decode")
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
        guard case .screenshotTaken(_, let time, _, _) = decoded else {
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

    // MARK: - D104's two fields, proved the same way rather than assumed

    /// The shape an older app wrote, before `.started` reported truncation.
    private static let oldStartedPayload =
        #"{"started":{"sessionID":"abc123","target":"Safari"}}"#

    @Test("A started payload written before vocabularyDropped existed still decodes")
    func oldStartedPayloadDecodes() throws {
        // Discriminates against declaring the field non-Optional with a default
        // (`vocabularyDropped: Int = 0`), which reads as harmless and is not:
        // synthesized Codable then REQUIRES the key, so this throws
        // `keyNotFound` and every agent talking to a not-yet-updated app breaks
        // on the very first call of the loop. `.stopped`'s "v2 has never
        // shipped" excuse is unavailable, since v2 ships in every release
        // from 0.2.0, so the compatibility has to be proved.
        let decoded = try JSONDecoder().decode(
            AutomationResponse.self, from: Data(Self.oldStartedPayload.utf8))
        guard case .started(let id, let target, let dropped) = decoded else {
            Issue.record("did not decode as started: \(decoded)"); return
        }
        #expect(id == "abc123")
        #expect(target == "Safari")
        #expect(dropped == nil)
    }

    @Test("A started round trip preserves a truncation count, including zero")
    func startedRoundTripsTheCount() throws {
        // Zero explicitly, because zero is NOT the same answer as nil: nil says
        // no vocabulary was sent, zero says terms were sent and all were kept.
        // Discriminates against an implementation that folds the two together
        // by encoding 0 as an absent key.
        for dropped in [nil, 0, 50] as [Int?] {
            let original = AutomationResponse.started(sessionID: "s", target: "t",
                                                      vocabularyDropped: dropped)
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(AutomationResponse.self, from: data)
            #expect(decoded == original, "lost \(String(describing: dropped))")
        }
    }

    /// The shape an older app wrote, before `StatusInfo` carried grants.
    ///
    /// Nested under `_0` because `.status` carries one UNLABELLED associated
    /// value, which is how synthesized Codable spells it. Written out rather
    /// than round-tripped from an encoder, so this asserts the shape an older
    /// build actually put on the wire instead of whatever today's code emits.
    private static let oldStatusPayload =
        #"{"status":{"_0":{"recording":false,"paused":false}}}"#

    @Test("A status payload written before `initiator` existed still decodes")
    func statusWithoutInitiatorDecodes() throws {
        // The trap that fired twice in one day: a non-Optional property makes
        // synthesized Codable REQUIRE its key, so every older app's status
        // response would decode as `keyNotFound`. `nil` means "this app does
        // not say", never "nobody started it".
        let old = #"{"status":{"_0":{"recording":true,"sessionID":"abc","paused":false}}}"#
        let decoded = try JSONDecoder().decode(
            AutomationResponse.self, from: Data(old.utf8))
        guard case .status(let info) = decoded else {
            Issue.record("did not decode as status: \(decoded)"); return
        }
        #expect(info.recording)
        #expect(info.initiator == nil, "absent must read as 'cannot say'")
    }

    @Test("A status payload written before the consent block existed still decodes")
    func oldStatusPayloadDecodes() throws {
        // Same discrimination as above, against `consent: ConsentInfo` with a
        // default rather than `ConsentInfo?`. `snitt_status` is the one tool an
        // agent is now told to call FIRST, so a keyNotFound here would break
        // the cold start of every loop against a not-yet-updated app.
        let decoded = try JSONDecoder().decode(
            AutomationResponse.self, from: Data(Self.oldStatusPayload.utf8))
        guard case .status(let info) = decoded else {
            Issue.record("did not decode as status: \(decoded)"); return
        }
        #expect(info.recording == false)
        // nil means "this app cannot say", which a caller must be able to tell
        // apart from "nothing is permitted".
        #expect(info.consent == nil)
    }

    @Test("A status round trip preserves the consent block")
    func statusRoundTripsConsent() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let grant = UnattendedRecordingGrant(
            agentRecordingEnabled: true, enabled: true,
            confirmedAt: now.addingTimeInterval(-86_400))
        let info = StatusInfo(recording: false, sessionID: nil, elapsedSeconds: nil,
                              consent: ConsentInfo(grant: grant, fullDisplay: true,
                                                   now: now))
        let original = AutomationResponse.status(info)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AutomationResponse.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - D107, proved the same way rather than assumed

    /// An `.export` REQUEST as a client built before D107's overlay overrides
    /// existed wrote it: nine fields, no `captions`, no `markerBanners`.
    private static let oldExportRequest = """
        {"protocolVersion":4,"body":{"export":{"bundlePath":"/tmp/x.snitt",\
        "format":"mp4","outputPath":"/tmp/d.mp4","scale":1,"chapters":false,\
        "subtitles":false,"resolution":"source","clicks":false}}}
        """

    @Test("An export request written before the overlay overrides existed still decodes")
    func oldExportRequestDecodes() throws {
        // The claim `AutomationProtocol.version`'s comment makes: those two
        // fields are additive and did NOT earn the bump to 4 on their own.
        // That is an assertion about Swift's synthesis for an enum case with
        // Optional associated values, and this project's own history says not
        // to assume it, `.stopped`'s "v2 has never shipped" reasoning was
        // true when written and false by the time somebody leaned on it.
        //
        // If synthesis required the keys rather than treating the Optionals as
        // absent-means-nil, this throws `keyNotFound` and every export request
        // from a not-yet-updated client fails at the socket.
        let decoded = try JSONDecoder().decode(
            AutomationRequest.self, from: Data(Self.oldExportRequest.utf8))
        guard case .export(let path, _, _, _, _, _, _, _, _,
                           let captions, let banners) = decoded.body else {
            Issue.record("did not decode as export: \(decoded.body)"); return
        }
        #expect(path == "/tmp/x.snitt")
        // And absent decodes as "the document decides", not as "off".
        #expect(captions == nil)
        #expect(banners == nil)
    }
}
