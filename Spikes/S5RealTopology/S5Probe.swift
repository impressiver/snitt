// THROWAWAY SPIKE CODE — spec §14, S5. Do not build on this.
//
// Question: when a client whose parent is NOT Snitt asks Snitt.app over a socket
// to capture, does the capture use SNITT'S grant and produce real frames?
//
// Run `S5Probe serve` from inside a granted Snitt.app context, and
// `S5Probe ask` from an unrelated parent process.
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics

let socketPath = "/tmp/snitt-s5.sock"

/// `serve` runs inside an app bundle launched via LaunchServices, so it has no
/// terminal to print to. Append to a file the human can read instead.
/// Log to /tmp instead of ~/Desktop: the latter is TCC-protected by the Files-and-Folders
/// service, silently defeating reads from both shell and the app. /tmp is unrestricted.
func log(_ message: String) {
    let url = URL(fileURLWithPath: "/tmp/snitt-s5.log")
    let line = Data((message + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile(); handle.write(line); try? handle.close()
    } else {
        try? line.write(to: url)
    }
}

@main
struct S5Probe {
    static func main() async {
        switch CommandLine.arguments.dropFirst().first ?? "ask" {
        case "serve": await serve()
        default:      ask()
        }
    }

    /// Listens on a Unix socket; on any byte, captures and reports frame counts.
    static func serve() async {
        // Preflight only READS the grant; Request is what raises the dialog and
        // registers this app in System Settings. A probe that skips Request
        // measures nothing and silently reports failure — this exact defect has
        // now appeared three times in this project.
        if !CGPreflightScreenCaptureAccess() {
            log("Screen Recording not yet granted — requesting (a dialog should appear)")
            let granted = CGRequestScreenCaptureAccess()
            log("CGRequestScreenCaptureAccess() returned: \(granted)")
            if !granted {
                log("DENIED. Grant S5Server in System Settings > Privacy & Security >")
                log("Screen & System Audio Recording, then relaunch this app.")
            }
        } else {
            log("Screen Recording already granted at start")
        }

        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { strcpy(UnsafeMutableRawPointer(ptr)
                .assumingMemoryBound(to: CChar.self), $0) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        listen(fd, 1)
        log("S5 server listening on \(socketPath)")

        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            var byte: UInt8 = 0
            _ = read(client, &byte, 1)
            let result = await capture()
            var reply = result + "\n"
            _ = reply.withUTF8 { write(client, $0.baseAddress, $0.count) }
            close(client)
            log("S5 server handled a request: \(result)")
        }
    }

    /// Connects and prints whatever the server reports.
    static func ask() {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { strcpy(UnsafeMutableRawPointer(ptr)
                .assumingMemoryBound(to: CChar.self), $0) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard ok == 0 else {
            print("S5 client: could not connect — is the server running?"); exit(1)
        }
        var go: UInt8 = 1
        _ = write(fd, &go, 1)
        var buffer = [UInt8](repeating: 0, count: 512)
        let n = read(fd, &buffer, 512)
        print("S5 client got: " + (String(bytes: buffer[0..<max(0, n)], encoding: .utf8) ?? "?"))
        close(fd)
    }

    /// Two seconds of capture, counting frames that carry real content.
    static func capture() async -> String {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return "NO DISPLAY" }
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            let collector = FrameCounter()
            let stream = SCStream(filter: SCContentFilter(display: display,
                                                          excludingWindows: []),
                                  configuration: config, delegate: nil)
            try stream.addStreamOutput(collector, type: .screen,
                                       sampleHandlerQueue: .global())
            try await stream.startCapture()
            try await Task.sleep(for: .seconds(2))
            try await stream.stopCapture()
            return "frames=\(collector.count) nonBlack=\(collector.nonBlack)"
        } catch {
            return "CAPTURE FAILED: \(error)"
        }
    }
}

final class FrameCounter: NSObject, SCStreamOutput, @unchecked Sendable {
    private(set) var count = 0
    private(set) var nonBlack = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        count += 1
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var sum = 0
        for row in Swift.stride(from: 0, to: CVPixelBufferGetHeight(pb), by: 32) {
            for col in Swift.stride(from: 0, to: stride, by: 256) {
                sum += Int(bytes[row * stride + col])
            }
        }
        if sum > 0 { nonBlack += 1 }
    }
}
