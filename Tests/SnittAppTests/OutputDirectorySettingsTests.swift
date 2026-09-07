import Testing
import Foundation
@testable import SnittApp

private func emptyDefaults() -> UserDefaults {
    let suite = "snitt.outputDirectory.\(UUID().uuidString)"
    UserDefaults().removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

@Test("Defaults to ~/Documents/Snitt for defaults that have never been written")
func outputDirectoryDefaultsToDocumentsSnitt() {
    // The product-owner directive this pins: NOT `~/Desktop` (the old
    // hardcoded value) and not an empty/garbage path — a specific, dedicated
    // subfolder of `~/Documents`, which (unlike `~/Desktop`) is not
    // TCC-protected under the Files-and-Folders service.
    let expected = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents")
        .appendingPathComponent("Snitt")
    #expect(OutputDirectorySettings.load(emptyDefaults()).directory.path == expected.path)
    #expect(OutputDirectorySettings().directory.path == expected.path)
}

@Test("The output directory survives a save and reload")
func outputDirectoryRoundTrips() {
    let defaults = emptyDefaults()
    let custom = URL(fileURLWithPath: "/Volumes/External/Recordings")
    OutputDirectorySettings(directory: custom).save(to: defaults)
    // Compared by `.path`, not raw `URL` equality — see
    // `OutputDirectorySettings.load`'s own doc comment on why forcing (or
    // mismatching) the `isDirectory` hint would make two URLs naming the
    // exact same folder compare unequal.
    #expect(OutputDirectorySettings.load(defaults).directory.path == custom.path)
}

@Test("A corrupt stored value reads as the default, not garbage")
func outputDirectoryCorruptValueReadsAsDefault() {
    let defaults = emptyDefaults()
    // Absent and invalid are DIFFERENT states, and both must read as the
    // default — the same rule `UpdateSettingsTests.corruptStoredValueReadsAsOff`
    // and `MicrophoneSettingsTests.microphoneCorruptValueReadsAsOff` pin for
    // their own (Bool) keys, applied here to a non-Bool one. Storing an
    // array under the key is exactly the shape `string(forKey:)` refuses to
    // coerce — an implementation that instead did
    // `defaults.object(forKey:) as? String ?? ""` then built a URL from
    // that would silently produce a URL pointing at "", not the default.
    defaults.set(["not", "a", "path"], forKey: "com.impressiver.snitt.outputDirectory")
    #expect(OutputDirectorySettings.load(defaults).directory.path == OutputDirectorySettings.defaultDirectory.path)
}

@Test("An empty stored string reads as the default rather than an empty-path URL")
func outputDirectoryEmptyStringReadsAsDefault() {
    let defaults = emptyDefaults()
    defaults.set("", forKey: "com.impressiver.snitt.outputDirectory")
    #expect(OutputDirectorySettings.load(defaults).directory.path == OutputDirectorySettings.defaultDirectory.path)
}
