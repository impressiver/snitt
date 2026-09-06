import Testing
@testable import SnittDocument

@Test("A version is always reported, even with no bundle")
func versionIsNeverEmpty() {
    // Under `swift test` there is no CFBundleShortVersionString. An empty
    // string here would reach `snitt --version` and every diagnostics
    // bundle, where it reads as "unknown build" to a support engineer.
    #expect(!AppVersion.current.isEmpty)
}

@Test("The version looks like a version")
func versionIsWellFormed() {
    // Sparkle compares this against the appcast. A value that is not
    // dotted-numeric makes every comparison meaningless, and the symptom is
    // "updates never appear" rather than an error.
    let parts = AppVersion.current.split(separator: ".")
    #expect(parts.count >= 2)
    #expect(parts.allSatisfy { $0.allSatisfy(\.isNumber) })
}
