import Foundation
import Testing
@testable import SnittDocument

/// `CaptureHealth.outputRoute` (D73): where the sound was going, recorded so a
/// poor transcript can be explained rather than merely observed.
@Suite
struct CaptureHealthRouteTests {

    @Test("The route survives a round trip")
    func routeRoundTrips() throws {
        let health = CaptureHealth(meanFrameVariance: 12, micRMS: 0.05,
                                   systemAudioRMS: 0.29, outputRoute: "builtInSpeakers")
        let decoded = try JSONDecoder().decode(
            CaptureHealth.self, from: JSONEncoder().encode(health))
        #expect(decoded == health)
        #expect(decoded.outputRoute == "builtInSpeakers")
    }

    @Test("Health written before this field existed still decodes")
    func olderHealthStillDecodes() throws {
        // Every recording made before today has no `outputRoute`. D54 makes
        // updates hand-delivered, so old and new builds coexist on one machine
        // and old bundles are opened by new code routinely — a required field
        // here would make every existing recording unreadable.
        let json = Data("""
        {"meanFrameVariance": 12.0, "micRMS": 0.05, "systemAudioRMS": 0.29}
        """.utf8)
        let decoded = try JSONDecoder().decode(CaptureHealth.self, from: json)
        #expect(decoded.outputRoute == nil)
        #expect(decoded.micRMS == 0.05)
    }

    @Test("The recording that motivated this is diagnosable from its health alone")
    func theBleedSignatureIsReadable() {
        // Snitt-1788900308.snitt's actual numbers. The point of storing the
        // route is that these three fields together say "the microphone was
        // recording the speakers", which no pair of them can.
        let health = CaptureHealth(micRMS: 0.0479, systemAudioRMS: 0.2861,
                                   outputRoute: "builtInSpeakers")
        let bledIntoTheMic = health.outputRoute == "builtInSpeakers"
            && health.micRMS != nil && health.systemAudioRMS != nil
        #expect(bledIntoTheMic)
    }
}
