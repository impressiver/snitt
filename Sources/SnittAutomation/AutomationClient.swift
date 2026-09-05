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
    /// The app accepted the connection but never answered. Distinct from
    /// `notRunning` on purpose: "Snitt is not running" and "Snitt is wedged"
    /// need different things from whoever reads it.
    case timedOut
    /// The socket could not be given a timeout, so a wedged app could hang this
    /// call forever. Refuse to proceed rather than make an unbounded call that
    /// looks bounded (§11).
    case timeoutUnavailable
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
    /// Bound on the whole round trip once connected, so a server that accepted
    /// the connection but never answers cannot hang the caller forever (§11).
    ///
    /// 120 seconds by default. That is deliberate, not arbitrary: `record stop`
    /// finalizes an `AVAssetWriter`, which for a long recording can legitimately
    /// take several seconds, so a tight bound would misfire on correct, if slow,
    /// operation. Tests pass something short instead of shrinking the default.
    private let timeout: TimeInterval

    public init(socketURL: URL = SocketPath.url(), timeout: TimeInterval = 120) {
        self.socketURL = socketURL
        self.timeout = timeout
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
        let timeout = self.timeout

        return try await withCheckedThrowingContinuation { continuation in
            let box = OnceBox(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                Self.performRoundTrip(path: path, payload: payload, timeout: timeout, box: box)
            }
        }
    }

    private static func performRoundTrip(path: String, payload: Data, timeout: TimeInterval, box: OnceBox) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { box.fail(ClientError.notRunning); return }
        defer { close(fd) }

        var tv = timeval()
        tv.tv_sec = Int(timeout)
        tv.tv_usec = Int32((timeout - Double(Int(timeout))) * 1_000_000)
        // The whole §11 guarantee rests on these two calls actually applying.
        // A silently-ignored failure would leave the socket blocking forever
        // while looking, to the next reader, like it was bounded — refuse to
        // proceed rather than make an unbounded call that looks bounded.
        let timeoutsApplied = withUnsafeBytes(of: &tv) { raw -> Bool in
            let rcv = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, raw.baseAddress, socklen_t(MemoryLayout<timeval>.size))
            let snd = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, raw.baseAddress, socklen_t(MemoryLayout<timeval>.size))
            return rcv == 0 && snd == 0
        }
        guard timeoutsApplied else {
            box.fail(ClientError.timeoutUnavailable)
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else {
            box.fail(ClientError.notRunning)
            return
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
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
            box.fail(errno == EAGAIN || errno == EWOULDBLOCK ? ClientError.timedOut : ClientError.notRunning)
            return
        }

        var framer = LineFramer()
        var readBuffer = [UInt8](repeating: 0, count: 65_536)

        while true {
            let n = readBuffer.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 {
                // A SO_RCVTIMEO expiry surfaces as read() returning -1 with
                // EAGAIN/EWOULDBLOCK: the server accepted us but never answered.
                box.fail(errno == EAGAIN || errno == EWOULDBLOCK ? ClientError.timedOut : ClientError.notRunning)
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
