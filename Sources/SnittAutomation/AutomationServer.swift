import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public protocol AutomationHandling: Sendable {
    func handle(_ body: AutomationRequest.Body) async -> AutomationResponse
}

/// Errors from the raw POSIX socket calls that back the server.
public enum ServerError: Error, Equatable {
    case socketCreationFailed
    case pathTooLong
    case bindFailed(String)
    case listenFailed(String)
}

/// Listens on a Unix domain socket and dispatches one request per line.
///
/// Uses raw POSIX `socket`/`bind`/`listen`/`accept` rather than Network.framework.
/// A Unix-domain `NWListener` bound via `requiredLocalEndpoint = .unix(path:)` is
/// an unverified recipe; the POSIX approach used here is the one already proven
/// against this exact socket path in `Spikes/S5RealTopology/S5Probe.swift`.
///
/// The version check lives here rather than in each handler: §10 requires a
/// mismatch to be refused outright rather than partially executed, and putting it
/// at the boundary means no handler can forget it.
public final class AutomationServer: @unchecked Sendable {
    private let socketURL: URL
    private let handler: AutomationHandling
    private let acceptQueue = DispatchQueue(label: "com.impressiver.snitt.automation.accept")

    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false

    public init(socketURL: URL, handler: AutomationHandling) {
        self.socketURL = socketURL
        self.handler = handler
    }

    public func start() throws {
        // A stale socket file from a crash would make bind fail.
        try? FileManager.default.removeItem(at: socketURL)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketCreationFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else {
            close(fd)
            throw ServerError.pathTooLong
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLength) { cptr in
                path.withCString { strcpy(cptr, $0) }
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bindResult == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw ServerError.bindFailed(message)
        }

        guard listen(fd, 16) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw ServerError.listenFailed(message)
        }

        stateLock.lock()
        listenFD = fd
        running = true
        stateLock.unlock()

        acceptQueue.async { [weak self] in
            self?.acceptLoop(fd: fd)
        }
    }

    public func stop() {
        stateLock.lock()
        running = false
        let fd = listenFD
        listenFD = -1
        stateLock.unlock()

        if fd >= 0 {
            // POSIX does not define what happens when another thread is blocked
            // in accept() on an fd that gets closed out from under it — the
            // number can be reused before the blocked call wakes. Shutting the
            // socket down first forces that accept() to return promptly.
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func isRunning() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    private func acceptLoop(fd: Int32) {
        while isRunning() {
            let client = accept(fd, nil, nil)
            guard client >= 0 else {
                if isRunning() { continue }
                return
            }
            let connFD = client
            Thread.detachNewThread { [weak self] in
                self?.handleConnection(connFD)
            }
        }
    }

    /// A client that connects and never sends a complete line would otherwise
    /// park this connection's thread forever. Snitt is a long-running app, so
    /// that is a slow thread leak rather than a test-only concern.
    private static let connectionReadTimeout: TimeInterval = 30

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }

        var tv = timeval()
        tv.tv_sec = Int(Self.connectionReadTimeout)
        tv.tv_usec = 0
        withUnsafeBytes(of: &tv) { raw in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, raw.baseAddress, socklen_t(MemoryLayout<timeval>.size))
        }

        var framer = LineFramer()
        var readBuffer = [UInt8](repeating: 0, count: 65_536)

        while true {
            let n = readBuffer.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { return }
            let chunk = Data(readBuffer[0..<n])

            let messages: [Data]
            do {
                messages = try framer.append(chunk)
            } catch {
                // Poisoned framer: further appends throw forever. Make a best
                // effort to tell the client why, then close regardless.
                let failure = AutomationResponse.failure(AutomationError(
                    code: .internalError,
                    message: "The request exceeded the maximum message size.",
                    hint: "Send a smaller request."))
                if let payload = try? JSONEncoder().encode(failure) {
                    _ = send(payload: LineFramer.frame(payload), to: fd)
                }
                return
            }

            for message in messages {
                let response = respond(to: message)
                guard let payload = try? JSONEncoder().encode(response) else { continue }
                guard send(payload: LineFramer.frame(payload), to: fd) else { return }
            }
        }
    }

    /// Writes the full buffer, looping over partial `write`s. Returns false on error.
    private func send(payload: Data, to fd: Int32) -> Bool {
        var offset = 0
        let count = payload.count
        return payload.withUnsafeBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return count == 0 }
            while offset < count {
                let written = write(fd, base + offset, count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    private func respond(to message: Data) -> AutomationResponse {
        do {
            let request = try JSONDecoder().decode(AutomationRequest.self, from: message)
            if request.protocolVersion != AutomationProtocol.version {
                return .failure(AutomationError(
                    code: .upgradeRequired,
                    message: "This Snitt speaks protocol \(AutomationProtocol.version); "
                           + "the client sent \(request.protocolVersion).",
                    hint: "Update whichever of the app or the CLI is older. Snitt "
                        + "refuses a mismatch rather than guessing at the format."))
            }
            let semaphore = DispatchSemaphore(value: 0)
            let box = ResponseBox()
            Task {
                box.value = await handler.handle(request.body)
                semaphore.signal()
            }
            semaphore.wait()
            return box.value ?? .failure(AutomationError(
                code: .internalError,
                message: "The handler produced no response."))
        } catch {
            return .failure(AutomationError(
                code: .internalError,
                message: "Could not decode the request.",
                hint: "This usually means a protocol mismatch between the CLI and the app."))
        }
    }
}

/// Bridges an async handler result back onto the blocking connection thread.
///
/// `value` is unsynchronised, but that is safe: the writing `Task` sets it and
/// then calls `semaphore.signal()`, and the reading thread only observes it
/// after `semaphore.wait()` returns. The semaphore's signal/wait pair is itself
/// a synchronisation primitive, so it establishes the happens-before edge that
/// makes the plain, lock-free field access correct.
private final class ResponseBox: @unchecked Sendable {
    var value: AutomationResponse?
}
