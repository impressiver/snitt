import Testing
import Foundation
@testable import SnittAutomation

/// Answers with a canned response and records what it was asked.
final class SpyHandler: AutomationHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var _received: [AutomationRequest.Body] = []
    var received: [AutomationRequest.Body] {
        lock.lock(); defer { lock.unlock() }; return _received
    }

    func handle(_ body: AutomationRequest.Body) async -> AutomationResponse {
        record(body)
        return .status(StatusInfo(recording: false, sessionID: nil, elapsedSeconds: nil))
    }

    private func record(_ body: AutomationRequest.Body) {
        lock.lock(); _received.append(body); lock.unlock()
    }
}

private func tempSocketURL() -> URL {
    // Short path: a Unix socket path is limited to ~104 bytes.
    URL(fileURLWithPath: "/tmp/snitt-test-\(UUID().uuidString.prefix(8)).sock")
}

@Test("A request reaches the handler and its response comes back")
func requestRoundTrips() async throws {
    let url = tempSocketURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let handler = SpyHandler()
    let server = AutomationServer(socketURL: url, handler: handler)
    try server.start()
    defer { server.stop() }

    let client = AutomationClient(socketURL: url)
    let response = try await client.send(.status)

    guard case .status(let info) = response else {
        Issue.record("expected a status response"); return
    }
    #expect(info.recording == false)
    #expect(handler.received.count == 1)
}

@Test("A client talking to nothing fails fast instead of hanging")
func noServerFailsFast() async {
    // An agent must never block on something it cannot see (§11).
    let client = AutomationClient(socketURL: tempSocketURL())
    await #expect(throws: ClientError.notRunning) {
        _ = try await client.send(.status)
    }
}

@Test("A protocol mismatch is refused with upgrade_required, not guessed at")
func versionMismatchIsRefused() async throws {
    let url = tempSocketURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let server = AutomationServer(socketURL: url, handler: SpyHandler())
    try server.start()
    defer { server.stop() }

    // Hand-roll a request from a "future" client.
    let request = AutomationRequest(protocolVersion: AutomationProtocol.version + 1,
                                    body: .status)
    let client = AutomationClient(socketURL: url)
    let response = try await client.sendRaw(request)

    guard case .failure(let error) = response else {
        Issue.record("a version mismatch must not be executed"); return
    }
    #expect(error.code == .upgradeRequired)
}
