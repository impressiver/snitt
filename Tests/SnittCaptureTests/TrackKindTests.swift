import Testing
import ScreenCaptureKit
@testable import SnittCapture

@Test("Every SCStreamOutputType maps to the expected track")
func mapsOutputTypes() {
    #expect(TrackKind(.screen) == .video)
    #expect(TrackKind(.audio) == .systemAudio)
    #expect(TrackKind(.microphone) == .microphone)
}

@Test("All three tracks are enumerable")
func allTracksEnumerable() {
    #expect(TrackKind.allCases.count == 3)
    #expect(Set(TrackKind.allCases.map(\.rawValue))
            == ["video", "systemAudio", "microphone"])
}
