import Testing
import Foundation
@testable import SnittDocument

@Test("A manifest with no size target round-trips with nil fields")
func noTargetRoundTrips() throws {
    let manifest = ExportManifest(outputPath: "/tmp/a.mp4", format: "mp4", byteSize: 100,
                                  durationSeconds: 1, width: 2, height: 2, scale: 1)
    let decoded = try JSONDecoder().decode(
        ExportManifest.self, from: JSONEncoder().encode(manifest))
    #expect(decoded.maxSizeBytes == nil)
    #expect(decoded.maxSizeMet == nil)
}

@Test("A missed size target survives encoding as false, not as absent")
func missedTargetRoundTrips() throws {
    // The discriminating case. An implementation that encodes maxSizeMet
    // only when true — or that uses `Bool` with a false default instead of
    // `Bool?` — makes "missed the target" indistinguishable from "no target
    // requested", and an agent attaches an oversized file believing it fits.
    let manifest = ExportManifest(outputPath: "/tmp/a.mp4", format: "mp4", byteSize: 999,
                                  durationSeconds: 1, width: 2, height: 2, scale: 1,
                                  maxSizeBytes: 500, maxSizeMet: false)
    let decoded = try JSONDecoder().decode(
        ExportManifest.self, from: JSONEncoder().encode(manifest))
    #expect(decoded.maxSizeBytes == 500)
    #expect(decoded.maxSizeMet == false)
    #expect(decoded.byteSize == 999)
}
