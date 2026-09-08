import CoreAudio
import Foundation

/// Where the Mac is currently playing sound.
///
/// Exists for one question: will the microphone record the system audio as well
/// as the voice? It will, unavoidably, if the sound is coming out of the Mac's
/// own speakers — and a recording made that way costs the whole take. D73 was
/// written from one: 32 seconds of narration over SoundCloud playback that
/// transcribed to five words, because the music arrived back through the
/// microphone louder than the speech and clipped at 2.216.
public enum AudioOutputRoute: String, Sendable, Codable, Equatable, CaseIterable {
    /// The Mac's own speakers. Anything they play, the microphone hears.
    case builtInSpeakers
    /// Headphones in the built-in jack. The reason this is a separate case and
    /// not folded into `external` is the whole difficulty of the check — see
    /// `classify`.
    case headphones
    /// USB, Bluetooth, HDMI, an aggregate device. Could be headphones, could be
    /// a speaker on the desk; the OS does not say which, so neither does this.
    case external
    case unknown
}

extension AudioOutputRoute {

    /// A four-character code as CoreAudio stores them.
    private static func fourCC(_ s: StaticString) -> UInt32 {
        var value: UInt32 = 0
        s.withUTF8Buffer { for byte in $0 { value = (value << 8) | UInt32(byte) } }
        return value
    }

    /// The Mac's internal speaker, as `kAudioDevicePropertyDataSource` reports it.
    static let internalSpeakerSource = fourCC("ispk")
    /// The built-in headphone jack.
    static let headphoneSource = fourCC("hdpn")

    /// Classify an output device from the two properties CoreAudio exposes.
    ///
    /// **Transport type alone is not enough, and using it alone is the obvious
    /// wrong implementation.** A Mac reports headphones plugged into its own
    /// 3.5mm jack as `kAudioDeviceTransportTypeBuiltIn`, exactly like its
    /// speakers — so a check that stopped at the transport would warn about
    /// bleed at someone wearing headphones, which is both wrong and the fastest
    /// way to teach them to ignore the warning. The data source is what
    /// separates the two.
    ///
    /// Anything not positively identified comes back `.unknown` rather than
    /// being guessed into `.builtInSpeakers`. This warning is only worth having
    /// if it is never wrong: D73 committed to a check rather than a heuristic,
    /// and the cost of staying silent is a bad take, while the cost of crying
    /// wolf is a warning nobody reads.
    static func classify(transportType: UInt32, dataSource: UInt32?) -> AudioOutputRoute {
        guard transportType == kAudioDeviceTransportTypeBuiltIn else {
            return transportType == 0 ? .unknown : .external
        }
        switch dataSource {
        case .some(internalSpeakerSource): return .builtInSpeakers
        case .some(headphoneSource): return .headphones
        default: return .unknown
        }
    }

    /// Whether a recording started right now would capture the system audio
    /// twice: once cleanly, and once through the microphone.
    ///
    /// Needs BOTH sources to be on. Recording system audio with no microphone
    /// has nothing to bleed into, and recording a voice with no system audio
    /// has nothing to bleed.
    public static func bleedRisk(route: AudioOutputRoute,
                                 capturingMicrophone: Bool,
                                 capturingSystemAudio: Bool) -> Bool {
        capturingMicrophone && capturingSystemAudio && route == .builtInSpeakers
    }

    // MARK: - The device query
    //
    // The untestable seam, kept as thin as it can be: two CoreAudio reads and
    // no decisions. Everything that decides anything is in `classify`, which a
    // test can drive with any device configuration rather than only the one
    // the test machine happens to have plugged in.

    /// What the default output device is right now.
    public static func current() -> AudioOutputRoute {
        guard let device = defaultOutputDevice() else { return .unknown }
        guard let transport = property(UInt32.self, from: device,
                                       selector: kAudioDevicePropertyTransportType,
                                       scope: kAudioObjectPropertyScopeGlobal)
        else { return .unknown }
        let source = property(UInt32.self, from: device,
                              selector: kAudioDevicePropertyDataSource,
                              scope: kAudioObjectPropertyScopeOutput)
        return classify(transportType: transport, dataSource: source)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        property(AudioDeviceID.self, from: AudioObjectID(kAudioObjectSystemObject),
                 selector: kAudioHardwarePropertyDefaultOutputDevice,
                 scope: kAudioObjectPropertyScopeGlobal)
            .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    private static func property<T>(_ type: T.Type, from object: AudioObjectID,
                                    selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, value)
        return status == noErr ? value.pointee : nil
    }
}
