import Foundation

/// The opt-in for automatic update checks (§5, Ruling R3).
///
/// Defaults to FALSE for defaults that have never been written. That is the
/// safety rule rather than a preference, mirroring `EventLoggingSettings`: an
/// update check is a network request that tells a server this machine runs
/// Snitt, at a moment the user did not pick. Info.plist's
/// `SUEnableAutomaticChecks = false` is the cold-start default for a fresh
/// install with no stored setting yet; this type is the user's actual choice
/// once they make one, and `UpdaterController` applies it at runtime.
///
/// `UserDefaults.bool(forKey:)` is the discriminator that keeps a corrupt or
/// absent stored value reading as off: it returns `false` both when the key
/// is missing and when the stored value isn't one it can coerce to a bool
/// (an array, a dictionary, garbage). An implementation that instead read
/// `object(forKey:) as? Bool ?? true` would flip a corrupt value to enabled
/// — exactly the silent-coercion shape this project has been bitten by
/// before. Absent and invalid are different states, but neither is "on".
public struct UpdateSettings: Sendable, Equatable {
    public var automaticChecksEnabled: Bool

    private static let automaticChecksEnabledKey = "com.impressiver.snitt.updateAutomaticChecksEnabled"

    public init(automaticChecksEnabled: Bool = false) {
        self.automaticChecksEnabled = automaticChecksEnabled
    }

    public static func load(_ defaults: UserDefaults = .standard) -> UpdateSettings {
        UpdateSettings(automaticChecksEnabled: defaults.bool(forKey: automaticChecksEnabledKey))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(automaticChecksEnabled, forKey: Self.automaticChecksEnabledKey)
    }
}
