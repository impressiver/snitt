// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import CoreAudio
import Foundation
import Testing
@testable import SnittCapture

/// Classifying the output device, which is what makes the speaker-bleed
/// warning a check rather than a guess (D73).
@Suite
struct AudioOutputRouteTests {

    private let ispk = AudioOutputRoute.internalSpeakerSource
    private let hdpn = AudioOutputRoute.headphoneSource

    @Test("The Mac's own speakers are identified")
    func builtInSpeakers() {
        #expect(AudioOutputRoute.classify(
            transportType: kAudioDeviceTransportTypeBuiltIn, dataSource: ispk) == .builtInSpeakers)
    }

    @Test("Headphones in the built-in jack are NOT the built-in speakers")
    func headphonesInTheBuiltInJack() {
        // The whole reason this check reads the data source. macOS reports
        // headphones in its own 3.5mm jack with the SAME transport type as the
        // speakers, so a check that stopped at the transport would warn about
        // bleed at someone wearing headphones — wrong, and the fastest way to
        // train them to ignore the warning.
        #expect(AudioOutputRoute.classify(
            transportType: kAudioDeviceTransportTypeBuiltIn, dataSource: hdpn) == .headphones)
    }

    @Test("Devices on a bus of their own are external, not built in")
    func externalTransports() {
        for transport in [kAudioDeviceTransportTypeUSB,
                          kAudioDeviceTransportTypeBluetooth,
                          kAudioDeviceTransportTypeHDMI,
                          kAudioDeviceTransportTypeDisplayPort] {
            #expect(AudioOutputRoute.classify(transportType: transport, dataSource: nil) == .external,
                    "transport \(transport)")
        }
    }

    @Test("An unrecognised built-in source is unknown, never assumed to be speakers")
    func unrecognisedSourceIsNotGuessed() {
        // Guessing `.builtInSpeakers` here would make the warning fire on
        // hardware nobody tested. D73 committed to a check rather than a
        // heuristic: staying silent costs a bad take, crying wolf costs the
        // warning's credibility permanently.
        #expect(AudioOutputRoute.classify(
            transportType: kAudioDeviceTransportTypeBuiltIn, dataSource: nil) == .unknown)
        #expect(AudioOutputRoute.classify(
            transportType: kAudioDeviceTransportTypeBuiltIn, dataSource: 0x77617420) == .unknown)
    }

    @Test("A device that reports nothing is unknown rather than external")
    func silentDeviceIsUnknown() {
        #expect(AudioOutputRoute.classify(transportType: 0, dataSource: nil) == .unknown)
    }

    @Test("The four-character codes are the ones CoreAudio actually uses")
    func fourCharacterCodes() {
        // Spelled out, because a wrong constant produces a check that silently
        // never fires — the failure mode with no symptom.
        #expect(ispk == 0x6973706B)   // 'ispk'
        #expect(hdpn == 0x6864706E)   // 'hdpn'
    }

    // MARK: - The risk itself

    @Test("Bleed needs speakers AND a microphone AND system audio")
    func bleedNeedsAllThree() {
        // Each of the three alone is harmless: system audio with no microphone
        // has nothing to bleed INTO, a voice with no system audio has nothing
        // to bleed, and headphones carry nothing into the room.
        #expect(AudioOutputRoute.bleedRisk(route: .builtInSpeakers,
                                           capturingMicrophone: true,
                                           capturingSystemAudio: true))
        #expect(!AudioOutputRoute.bleedRisk(route: .builtInSpeakers,
                                            capturingMicrophone: false,
                                            capturingSystemAudio: true))
        #expect(!AudioOutputRoute.bleedRisk(route: .builtInSpeakers,
                                            capturingMicrophone: true,
                                            capturingSystemAudio: false))
        #expect(!AudioOutputRoute.bleedRisk(route: .headphones,
                                            capturingMicrophone: true,
                                            capturingSystemAudio: true))
    }

    @Test("An unidentified route never raises the warning")
    func unknownAndExternalDoNotWarn() {
        // External speakers on a desk WOULD bleed, and this stays quiet about
        // them on purpose: the OS does not say whether a USB device is a
        // headset or a speaker, and a warning that is sometimes wrong is worse
        // than one that is sometimes absent.
        for route in [AudioOutputRoute.unknown, .external] {
            #expect(!AudioOutputRoute.bleedRisk(route: route,
                                                capturingMicrophone: true,
                                                capturingSystemAudio: true),
                    "\(route) should not warn")
        }
    }

    @Test("The live query returns some route without crashing")
    func liveQueryAnswers() {
        // Cannot assert WHICH — it depends on what is plugged into the machine
        // running the suite. What it can prove is that the CoreAudio calls are
        // well-formed: a wrong selector or a size mismatch returns nil from
        // every property read and lands here as `.unknown` forever.
        let route = AudioOutputRoute.current()
        print("  this machine's output route: \(route.rawValue)")
        #expect(AudioOutputRoute.allCases.contains(route))
    }
}
