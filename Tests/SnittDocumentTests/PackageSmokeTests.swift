import Testing
@testable import SnittDocument

@Test("SnittDocument target builds and exposes its version")
func documentTargetIsLinkable() {
    #expect(SnittDocument.version == "0.1.0")
}
