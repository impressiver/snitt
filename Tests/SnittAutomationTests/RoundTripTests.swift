// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import SnittAutomation

/// Answers with a canned response and records what it was asked.
final class SpyHandler: AutomationHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var _received: [AutomationRequest.Body] = []
    var received: [AutomationRequest.Body] {
        lock.lock(); defer { lock.unlock() }; return _received
    }

    /// Records the caller too, so a round-trip test can assert the server
    /// actually reads the peer rather than passing nil through.
    private(set) var lastCaller: PeerIdentity?

    func handle(_ body: AutomationRequest.Body,
                caller: PeerIdentity?) async -> AutomationResponse {
        lastCaller = caller
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

/// Binds, listens and accepts connections but never writes back — simulates a
/// wedged Snitt.app: alive, and it accepted the connection, but it never answers.
final class SilentPeer: @unchecked Sendable {
    private let socketURL: URL
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "silent-peer.accept")

    init(socketURL: URL) {
        self.socketURL = socketURL
    }

    func start() throws {
        try? FileManager.default.removeItem(at: socketURL)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketCreationFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLength) { cptr in
                path.withCString { strcpy(cptr, $0) }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bindResult == 0 else { close(fd); throw ServerError.bindFailed("bind failed") }
        // Backlog of 8, not 1: `AutomationClient.send` probes with `canConnect`
        // BEFORE the request connection, so a single round trip arrives here as
        // two connections. With a backlog of one and a single `accept` below,
        // the second was intermittently refused and the client reported
        // `notRunning` in 0.001s instead of timing out in 1s — a flake that
        // failed roughly one run in five and looked like the timeout itself
        // regressing.
        guard listen(fd, 8) == 0 else { close(fd); throw ServerError.listenFailed("listen failed") }

        self.fd = fd
        queue.async { [fd] in
            // Accept every connection and then sit on it, never reading or
            // writing, until the socket is torn down by stop(). A loop rather
            // than one `accept` for the same reason as the backlog above: the
            // probe and the request are two connections, and accepting only
            // the first leaves the one under test unattended.
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }        // the listener was closed by stop()
                // Deliberately never closed: closing would send EOF, and this
                // peer exists to model a process that is alive and silent.
            }
        }
    }

    func stop() {
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            fd = -1
        }
        try? FileManager.default.removeItem(at: socketURL)
    }
}

/// Resumes at most once with whichever task finishes first. Deliberately NOT
/// `withTaskGroup`: that API waits for every child task to finish before
/// returning, even after `cancelAll()` — and a task blocked in a raw,
/// non-cancellable POSIX `read()` never finishes, so the group itself would
/// hang. An unstructured race avoids that: the loser is simply abandoned
/// rather than awaited.
private final class RaceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    init(_ continuation: CheckedContinuation<String, Never>) { self.continuation = continuation }
    func resume(_ value: String) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: value)
    }
}

@Test("A server that accepts but never answers times out instead of hanging forever")
func wedgedServerTimesOut() async throws {
    // §11: an agent must never block on something it cannot see. A process that
    // is alive and accepted the connection, but never replies, is exactly that —
    // and it is the failure a hand-rolled socket server is most prone to.
    let url = tempSocketURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let silent = SilentPeer(socketURL: url)   // accepts, never writes
    try silent.start()
    defer { silent.stop() }

    // The watchdog is deliberately independent of the socket timeout under test.
    // Without it this test is bounded only by the mechanism it is testing, so a
    // regression would wedge the whole suite instead of failing this one case.
    let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
        let box = RaceBox(continuation)
        Task {
            let client = AutomationClient(socketURL: url, timeout: 1)
            do { _ = try await client.send(.status); box.resume("returned") }
            catch ClientError.timedOut { box.resume("timedOut") }
            catch { box.resume("other:\(error)") }
        }
        Task {
            try? await Task.sleep(for: .seconds(10))
            box.resume("watchdog")
        }
    }
    #expect(outcome == "timedOut",
            "expected a bounded timeout; 'watchdog' means the call hung")
}
