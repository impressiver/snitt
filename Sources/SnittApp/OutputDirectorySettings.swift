import Foundation

/// Where finished recordings are saved (D56/M5d's deferred output-location
/// item, pulled forward for M5f on request).
///
/// Two independent reasons this needs to be a setting at all, not just a
/// changed constant:
///
/// 1. Users have opinions about where files land. A recorder that scatters
///    bundles wherever the author hardcoded, with no say, is a recorder
///    people stop using.
/// 2. `~/Desktop` — the OLD hardcoded default — is TCC-protected under the
///    Files-and-Folders service. Confirmed directly: `ls ~/Desktop` returns
///    "Operation not permitted" for a process without that grant, while
///    `~/Documents` reads fine. So no script, test, or `snitt diagnostics`
///    inspection could ever see a recording under that default. Being able
///    to point Snitt somewhere unprotected is what makes a recording
///    inspectable at all without a human first walking through System
///    Settings.
///
/// Stored as a plain `String` path, not a security-scoped bookmark: Snitt is
/// not sandboxed (no App Sandbox entitlement), so there is no security scope
/// to resume and no `startAccessingSecurityScopedResource()` dance — an
/// ordinary path is everything a non-sandboxed process needs. Reach for a
/// bookmark only if Snitt is ever sandboxed.
public struct OutputDirectorySettings: Sendable, Equatable {
    public var directory: URL

    private static let directoryKey = "com.impressiver.snitt.outputDirectory"

    /// `~/Documents/Snitt`, not `~/Desktop` — the default changed, not just
    /// whether it can be changed, on the product owner's direction. Why:
    ///
    /// 1. Nobody but the maintainer has this build (D61); there is no
    ///    installed base whose recordings would move out from under it the
    ///    way there would be for an already-shipped app, so the usual
    ///    "don't move anyone's files" caution does not apply here.
    /// 2. `~/Desktop` is TCC-protected (see this type's own doc comment
    ///    above) and `~/Documents` is not — so the default itself is what
    ///    makes a fresh install's recordings inspectable by tooling, with no
    ///    setup required.
    ///
    /// A dedicated `Snitt` subfolder, not bare `~/Documents`, keeps
    /// recordings from scattering into a folder most people already fill
    /// with unrelated files.
    ///
    /// Existing recordings already sitting on the Desktop are NOT moved, and
    /// Snitt never goes looking for them there — a user who had recordings
    /// on the Desktop still has them; only new ones land in the new place.
    public static let defaultDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Documents")
        .appendingPathComponent("Snitt")

    public init(directory: URL = Self.defaultDirectory) {
        self.directory = directory
    }

    /// `string(forKey:)` is the discriminator that keeps an ABSENT or
    /// CORRUPT stored value reading as the default — the same
    /// `bool(forKey:)` reasoning `UpdateSettings`/`CrashReportSettings` give
    /// for their own (Bool) keys, applied to a non-Bool one: it returns nil
    /// both when the key was never written and when whatever IS stored under
    /// it isn't a String (an array, a number, garbage), so both states fall
    /// through to the same default rather than one of them silently
    /// coercing into something else. Absent and invalid are different
    /// states, but neither is a directory Snitt should trust — this project
    /// has been bitten by exactly that shape of silent coercion before.
    ///
    /// Reconstructed with the plain `URL(fileURLWithPath:)` initializer, NOT
    /// the `isDirectory:` overload: forcing that hint on a URL built from a
    /// bare path string makes it compare unequal (via `URL`'s own
    /// `Equatable`, which is sensitive to it) to an equivalent URL a caller
    /// built without the hint — e.g. `NSOpenPanel`'s own `.urls` — even
    /// though both name the exact same folder on disk. Every other file URL
    /// in this codebase is built the same plain way, and matching that
    /// convention here is what keeps a round-tripped directory comparing
    /// equal to the one that was saved.
    public static func load(_ defaults: UserDefaults = .standard) -> OutputDirectorySettings {
        guard let path = defaults.string(forKey: directoryKey), !path.isEmpty else {
            return OutputDirectorySettings()
        }
        return OutputDirectorySettings(directory: URL(fileURLWithPath: path))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(directory.path, forKey: Self.directoryKey)
    }
}
