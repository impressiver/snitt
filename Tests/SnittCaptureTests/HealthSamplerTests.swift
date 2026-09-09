// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
import CoreVideo
@testable import SnittCapture

@Test("A constant image has zero variance — the frozen/black case")
func constantImageHasZeroVariance() {
    #expect(HealthSampler.variance(ofLuma: [40, 40, 40, 40]) == 0)
}

@Test("A varied image has non-zero variance")
func variedImageHasVariance() {
    #expect(HealthSampler.variance(ofLuma: [0, 255, 0, 255]) > 1000)
}

@Test("Variance of fewer than two samples is zero, not a divide by zero")
func varianceOfTooFewSamples() {
    #expect(HealthSampler.variance(ofLuma: []) == 0)
    #expect(HealthSampler.variance(ofLuma: [42]) == 0)
}

@Test("Silence has zero RMS — the dead-microphone case")
func silenceHasZeroRMS() {
    #expect(HealthSampler.rms(ofFloatSamples: [0, 0, 0, 0]) == 0)
}

@Test("A full-scale square wave has RMS 1")
func fullScaleHasRMSOne() {
    // RMS of ±1 is exactly 1. A sampler that averaged amplitudes instead of
    // their squares would also return 1 here, so the next test separates them.
    #expect(abs(HealthSampler.rms(ofFloatSamples: [1, -1, 1, -1]) - 1.0) < 0.0001)
}

@Test("RMS is root-mean-SQUARE, not mean amplitude")
func rmsIsNotMeanAmplitude() {
    // mean(|x|) of [1, 0] is 0.5; RMS is sqrt(0.5) ≈ 0.7071. A sampler that
    // averaged amplitudes would report 0.5 and pass every other test here.
    #expect(abs(HealthSampler.rms(ofFloatSamples: [1, 0]) - 0.70710678) < 0.0001)
}

@Test("A biplanar 4:2:0 frame — ScreenCaptureKit's actual default — does contribute a sample")
func biplanarFrameContributesASample() {
    // ScreenCaptureKit's real default (confirmed on-device: '420v') is
    // biplanar 4:2:0 YUV, not BGRA — CaptureSession never sets
    // configuration.pixelFormat. Plane 0 is full-resolution luma, so this
    // must be measured, not skipped: skipping it is exactly the bug that
    // shipped, where meanFrameVariance was nil for every real recording.
    let sampler = HealthSampler()
    let buffer = makeVideoBuffer(at: 0, size: CGSize(width: 128, height: 128),
                                  pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    sampler.observe(buffer, track: .video)
    #expect(sampler.result().meanFrameVariance != nil,
            "a biplanar frame must be measured, not skipped")
}

@Test("A BGRA frame does contribute a sample")
func bgraFrameContributesASample() {
    // The biplanar test alone would pass against a guard written against the
    // WRONG constant. This is the half that pins the (secondary) BGRA path.
    let sampler = HealthSampler()
    sampler.observe(makeVideoBuffer(at: 0, size: CGSize(width: 320, height: 240)), track: .video)
    #expect(sampler.result().meanFrameVariance != nil,
            "a BGRA frame must be measured, not skipped")
}

@Test("An unrecognised pixel layout contributes no sample rather than a false measurement")
func unknownFormatContributesNoSample() {
    // Neither biplanar 4:2:0 nor chunky BGRA. Reading it with either plane
    // or chunky arithmetic would misinterpret the memory layout and produce
    // a plausible-looking but meaningless number; skipping and reporting nil
    // ("we did not measure") is honest where a number would not be.
    let sampler = HealthSampler()
    let buffer = makeVideoBuffer(at: 0, size: CGSize(width: 128, height: 128),
                                  pixelFormat: kCVPixelFormatType_16Gray)
    sampler.observe(buffer, track: .video)
    #expect(sampler.result().meanFrameVariance == nil)
}
