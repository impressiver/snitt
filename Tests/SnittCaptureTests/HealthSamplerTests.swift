import Testing
import Foundation
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
