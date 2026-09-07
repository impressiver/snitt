import Foundation

/// The opt-in for capturing microphone audio (§4.2, §4.10 rung 2).
///
/// Defaults to FALSE for defaults that have never been written — the same
/// safety rule `EventLoggingSettings` states: enabling it costs the user a
/// second TCC dialog, paid only when someone deliberately wants voiceover.
/// Most demos do not need it, and defaulting it on would turn every first
/// run into two dialogs instead of one (§4.10's ladder).
public struct MicrophoneSettings: Sendable, Equatable {
    public var enabled: Bool

    private static let enabledKey = "com.impressiver.snitt.microphoneEnabled"

    public init(enabled: Bool = false) { self.enabled = enabled }

    public static func load(_ defaults: UserDefaults = .standard) -> MicrophoneSettings {
        MicrophoneSettings(enabled: defaults.bool(forKey: enabledKey))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
    }
}
