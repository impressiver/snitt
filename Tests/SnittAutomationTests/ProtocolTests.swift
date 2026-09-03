import Testing
import Foundation
@testable import SnittAutomation

@Test("A request round-trips through JSON with its protocol version intact")
func requestRoundTrips() throws {
    let request = AutomationRequest(
        protocolVersion: AutomationProtocol.version,
        body: .startRecording(StartOptions(bundleIdentifier: "com.apple.Safari",
                                           displayID: nil,
                                           microphone: false,
                                           systemAudio: true,
                                           maxDurationSeconds: 300))
    )
    let data = try JSONEncoder().encode(request)
    let back = try JSONDecoder().decode(AutomationRequest.self, from: data)

    #expect(back.protocolVersion == AutomationProtocol.version)
    guard case .startRecording(let options) = back.body else {
        Issue.record("wrong body case"); return
    }
    #expect(options.bundleIdentifier == "com.apple.Safari")
    #expect(options.systemAudio == true)
    #expect(options.microphone == false)
}

@Test("Every response case round-trips")
func responsesRoundTrip() throws {
    let cases: [AutomationResponse] = [
        .handshake(HandshakeInfo(protocolVersion: 1, appVersion: "0.1.0")),
        .targets([TargetSummary(id: 7, kind: "window", title: "Docs",
                                applicationName: "Safari",
                                bundleIdentifier: "com.apple.Safari")]),
        .started(sessionID: "abc", target: "Safari"),
        .stopped(bundlePath: "/tmp/x.snitt"),
        .status(StatusInfo(recording: true, sessionID: "abc", elapsedSeconds: 4)),
        .failure(AutomationError(code: .consentRequired, message: "m", hint: "h")),
    ]
    for value in cases {
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(AutomationResponse.self, from: data)
        #expect(back == value)
    }
}

@Test("Error codes are stable strings — agents branch on these, not on prose")
func errorCodesAreStable() {
    #expect(AutomationError.Code.consentRequired.rawValue == "consent_required")
    #expect(AutomationError.Code.upgradeRequired.rawValue == "upgrade_required")
    #expect(AutomationError.Code.noSuchSession.rawValue == "no_such_session")
    #expect(AutomationError.Code.alreadyRecording.rawValue == "already_recording")
    #expect(AutomationError.Code.targetNotFound.rawValue == "target_not_found")
    #expect(AutomationError.Code.permissionDenied.rawValue == "permission_denied")
    #expect(AutomationError.Code.internalError.rawValue == "internal_error")
}

@Test("Every error code maps to a distinct non-zero exit code")
func exitCodesAreDistinctAndNonZero() {
    let codes = AutomationError.Code.allCases
    let exits = codes.map { AutomationError.exitCode[$0] ?? -1 }
    #expect(exits.allSatisfy { $0 > 0 }, "success is 0; every failure must differ from it")
    #expect(Set(exits).count == codes.count, "an agent must be able to tell them apart")
}

@Test("The socket lives under Application Support, not /tmp")
func socketPathIsNotWorldWritable() {
    let path = SocketPath.url().path
    #expect(path.contains("Application Support/Snitt"))
    #expect(!path.hasPrefix("/tmp"), "/tmp is world-writable; another user could squat the socket")
}
