import Testing
import Foundation
@testable import SnittAutomation
import SnittDocument

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
        .stopped(bundlePath: "/tmp/x.snitt", health: nil),
        .stopped(bundlePath: "/tmp/y.snitt",
                health: CaptureHealth(meanFrameVariance: 1.2, micRMS: 0.3, systemAudioRMS: nil)),
        .status(StatusInfo(recording: true, sessionID: "abc", elapsedSeconds: 4)),
        .failure(AutomationError(code: .consentRequired, message: "m", hint: "h")),
    ]
    for value in cases {
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(AutomationResponse.self, from: data)
        #expect(back == value)
    }
}

@Test("healthFields omits an absent metric rather than reporting it as null or zero")
func healthFieldsOmitsAbsentMetrics() {
    let health = CaptureHealth(meanFrameVariance: 1.5, micRMS: nil, systemAudioRMS: 0.02)
    let fields = healthFields(health)
    #expect(fields["meanFrameVariance"] == 1.5)
    #expect(fields["systemAudioRMS"] == 0.02)
    #expect(fields["micRMS"] == nil,
            "a nil metric must be an ABSENT key — an agent branching on key presence would otherwise read a dead microphone as a reported measurement")
    #expect(fields.count == 2, "no extra key for the absent metric, however it might be encoded")
}

@Test("A nil CaptureHealth yields no fields at all")
func nilHealthYieldsNoFields() {
    #expect(healthFields(nil).isEmpty)
}

@Test("sizeBudgetNote reports a missed budget with both numbers")
func sizeBudgetNoteReportsAMiss() {
    let manifest = ExportManifest(outputPath: "/tmp/a.mp4", format: "mp4", byteSize: 9_000_000,
                                  durationSeconds: 1, width: 2, height: 2, scale: 1,
                                  maxSizeBytes: 5_000_000, maxSizeMet: false)
    let note = sizeBudgetNote(manifest)
    #expect(note?.contains("9.0 MB") == true)
    #expect(note?.contains("5.0 MB") == true)
}

@Test("sizeBudgetNote is nil when no target was requested")
func sizeBudgetNoteNilWithNoTarget() {
    let manifest = ExportManifest(outputPath: "/tmp/a.mp4", format: "mp4", byteSize: 9_000_000,
                                  durationSeconds: 1, width: 2, height: 2, scale: 1)
    #expect(sizeBudgetNote(manifest) == nil)
}

@Test("sizeBudgetNote is nil when the target was met")
func sizeBudgetNoteNilWhenMet() {
    let manifest = ExportManifest(outputPath: "/tmp/a.mp4", format: "mp4", byteSize: 3_000_000,
                                  durationSeconds: 1, width: 2, height: 2, scale: 1,
                                  maxSizeBytes: 5_000_000, maxSizeMet: true)
    #expect(sizeBudgetNote(manifest) == nil)
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

@Test("The protocol version is 3 — a new request case is not backward compatible")
func protocolVersionIsThree() {
    // An old app receiving a case it has no decoder for reports internal_error.
    // §10 requires a mismatch to be refused outright with a usable message, so
    // the version moves and the handshake produces upgrade_required instead.
    //
    // 2 -> 3 for `.crop`. Every earlier addition to v2 amended it without a
    // bump on the stated grounds that no v2 client had shipped; v0.1.0 has
    // shipped now, so that reasoning has expired and the next case earns a
    // bump. This test exists so the version cannot drift silently away from
    // the wire format.
    #expect(AutomationProtocol.version == 3)
}

@Test("StartOptions carries the client's working directory")
func startOptionsCarryWorkingDirectory() throws {
    // Snitt.app's own cwd is "/" — only the client knows which repository a
    // recording is about (§7).
    var options = StartOptions(bundleIdentifier: "com.apple.Safari")
    options.workingDirectory = "/Users/x/project"
    let back = try JSONDecoder().decode(
        StartOptions.self, from: JSONEncoder().encode(options))
    #expect(back.workingDirectory == "/Users/x/project")
}

@Test("StartOptions still decodes when workingDirectory is absent")
func workingDirectoryIsOptional() throws {
    let json = Data(#"{"microphone":false,"systemAudio":true}"#.utf8)
    let options = try JSONDecoder().decode(StartOptions.self, from: json)
    #expect(options.workingDirectory == nil)
}

@Test("A mark request round-trips with its session and label")
func markRoundTrips() throws {
    let request = AutomationRequest(body: .mark(sessionID: "abc", label: "ran tests"))
    let back = try JSONDecoder().decode(
        AutomationRequest.self, from: JSONEncoder().encode(request))
    guard case .mark(let session, let label) = back.body else {
        Issue.record("wrong body case"); return
    }
    #expect(session == "abc")
    #expect(label == "ran tests")
}

@Test("A marked response carries the time the marker landed at")
func markedResponseRoundTrips() throws {
    let response = AutomationResponse.marked(timeSeconds: 12.5)
    let back = try JSONDecoder().decode(
        AutomationResponse.self, from: JSONEncoder().encode(response))
    #expect(back == response)
}
