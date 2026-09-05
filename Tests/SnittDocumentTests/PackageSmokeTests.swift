import Testing
@testable import SnittDocument

@Test("SnittDocument target builds and exposes a version")
func documentTargetIsLinkable() {
    #expect(!AppVersion.current.isEmpty)
}
