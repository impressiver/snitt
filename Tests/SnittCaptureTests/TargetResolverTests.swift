import Testing
import Foundation
import ScreenCaptureKit
@testable import SnittCapture

/// A resolver that returns a canned result, so callers can be tested with no
/// picker UI and no real screen.
final class StubResolver: TargetResolver, @unchecked Sendable {
    let result: Result<ResolvedTarget, TargetResolutionError>
    private(set) var callCount = 0

    init(_ result: Result<ResolvedTarget, TargetResolutionError>) {
        self.result = result
    }

    func resolve() async throws -> ResolvedTarget {
        callCount += 1
        return try result.get()
    }
}

@Test("A resolver that fails surfaces its error unchanged")
func resolverPropagatesError() async {
    let resolver = StubResolver(.failure(.noCachedTarget))
    await #expect(throws: TargetResolutionError.noCachedTarget) {
        _ = try await resolver.resolve()
    }
    #expect(resolver.callCount == 1)
}

@Test("Provenance distinguishes picker from cache for spike S4")
func provenanceIsDistinguishable() {
    #expect(ResolvedTarget.Provenance.picker.rawValue == "picker")
    #expect(ResolvedTarget.Provenance.cache.rawValue == "cache")
    #expect(ResolvedTarget.Provenance.picker != ResolvedTarget.Provenance.cache)
}

@Test("Resolution errors are distinguishable by case")
func errorsAreDistinguishable() {
    #expect(TargetResolutionError.cancelled != TargetResolutionError.noCachedTarget)
    #expect(TargetResolutionError.targetGone("Safari")
            != TargetResolutionError.targetGone("Xcode"))
}
