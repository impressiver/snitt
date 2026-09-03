import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ClientError: Error, Equatable {
    /// Nothing is listening — Snitt.app is not running.
    case notRunning
    case malformedResponse
}

/// The client half, shared by the CLI and the MCP server.
///
/// Both frontends go through this type so their behaviour cannot diverge (§4.8).
/// Neither ever touches ScreenCaptureKit: the app holds the capture grant (§4.9).
///
/// Uses raw POSIX sockets rather than Network.framework, matching
/// `AutomationServer` — see its header comment for why. The round trip runs on a
/// real background thread (`DispatchQueue.global`), never on the Swift Concurrency
/// cooperative pool, so a blocking `read`/`write` cannot starve other tasks.
public struct AutomationClient: Sendable {
    private let socketURL: URL

    public init(socketURL: URL = SocketPath.url()) {
        self.socketURL = socketURL
    }

    public func send(_ body: AutomationRequest.Body) async throws -> AutomationResponse {
        try await sendRaw(AutomationRequest(body: body))
    }

    public func sendRaw(_ request: AutomationRequest) async throws -> AutomationResponse {
        // Fail fast rather than block on something we cannot see (§11): if the
        // socket file is not there, nothing is listening.
        guard FileManager.default.fileExists(atPath: socketURL.path) else {
            throw ClientError.notRunning
        }

        let payload = try JSONEncoder().encode(request)
        let path = socketURL.path

        return try await withCheckedThrowingContinuation { continuation in
            let box = OnceBox(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                Self.performRoundTrip(path: path, payload: payload, box: box)
            }
        }
    }

    private static func performRoundTrip(path: String, payload: Data, box: OnceBox) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { box.fail(ClientError.notRunning); return }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else {
            box.fail(ClientError.notRunning)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLength) { cptr in
                path.withCString { strcpy(cptr, $0) }
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connectResult == 0 else {
            box.fail(ClientError.notRunning)
            return
        }

        let framed = LineFramer.frame(payload)
        guard writeAll(framed, to: fd) else {
            box.fail(ClientError.notRunning)
            return
        }

        var framer = LineFramer()
        var readBuffer = [UInt8](repeating: 0, count: 65_536)

        while true {
            let n = readBuffer.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 {
                box.fail(ClientError.notRunning)
                return
            }
            let chunk = Data(readBuffer[0..<n])

            let messages: [Data]
            do {
                messages = try framer.append(chunk)
            } catch {
                // Poisoned framer: the server exceeded the maximum message size
                // (or sent something malformed enough to look like it did).
                box.fail(ClientError.malformedResponse)
                return
            }

            for message in messages {
                guard let response = try? JSONDecoder().decode(AutomationResponse.self, from: message) else {
                    box.fail(ClientError.malformedResponse)
                    return
                }
                box.succeed(response)
                return
            }
        }
    }

    /// Writes the full buffer, looping over partial `write`s. Returns false on error.
    private static func writeAll(_ payload: Data, to fd: Int32) -> Bool {
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
}

/// Resumes a continuation at most once. Network callbacks can fire more than
/// once, and resuming twice traps.
private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AutomationResponse, Error>?

    init(_ continuation: CheckedContinuation<AutomationResponse, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: AutomationResponse) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: value)
    }

    func fail(_ error: Error) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(throwing: error)
    }
}
