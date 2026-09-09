// THROWAWAY SPIKE CODE — spec section 14, S3. Do not build on this.
// Question: does SCStream capture correctly when triggered from a
// background (non-foreground) process?
import Foundation
@preconcurrency import ScreenCaptureKit
import AVFoundation

@main
struct Probe {
    static func main() async {
        let mode = CommandLine.arguments.dropFirst().first ?? "foreground"
        print("S3 probe running in mode: \(mode)")
        print("Process is frontmost: \(NSRunningApplication.current.isActive)")

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                print("RESULT: no displays available"); exit(2)
            }
            print("Displays visible: \(content.displays.count)")
            print("Windows visible:  \(content.windows.count)")

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.capturesAudio = true
            config.captureMicrophone = false

            let collector = FrameCollector()
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(collector, type: .screen,
                                       sampleHandlerQueue: .global())
            try await stream.startCapture()
            try await Task.sleep(for: .seconds(5))
            try await stream.stopCapture()

            print("--- RESULTS ---")
            print("Frames received:    \(collector.frameCount)")
            print("Non-black frames:   \(collector.nonBlackFrameCount)")
        } catch {
            print("RESULT: capture FAILED with: \(error)")
            exit(1)
        }
    }
}

final class FrameCollector: NSObject, SCStreamOutput, @unchecked Sendable {
    private(set) var frameCount = 0
    private(set) var nonBlackFrameCount = 0

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        frameCount += 1
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            var sum = 0
            for row in Swift.stride(from: 0, to: height, by: 32) {
                sum += Int(bytes[row * stride])
            }
            if sum > 0 { nonBlackFrameCount += 1 }
        }
    }
}
