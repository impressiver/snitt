// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittDocument

/// Waveform and filmstrip samples are taken in SOURCE time and drawn on an
/// OUTPUT axis. This is that join.
///
/// Every test below uses a recording WITH a cut, because without one the two
/// clocks agree and an implementation that ignored `keptRanges` entirely would
/// pass — which is the M4b Critical #1 shape: two clocks that look identical
/// until something is removed.
@Suite
struct TimelineSampleIndexTests {
    // 10s source, 2s removed from 2...4. Output is 8s long.
    private let kept = [TimeRange(start: 0, end: 2), TimeRange(start: 4, end: 10)]

    @Test("Before the cut, output and source agree")
    func beforeTheCut() {
        let index = TimelineSampleIndex.index(forOutputSeconds: 1.0, keptRanges: kept,
                                              samplesPerSecond: 10, sampleCount: 100)
        #expect(index == 10)
    }

    @Test("After the cut, the index skips the removed span")
    func afterTheCut() {
        // Output 3s is source 5s, because 2s were removed. An implementation
        // treating output as source returns 30 here — the whole defect this
        // type exists to prevent, and the assertion that catches it.
        let index = TimelineSampleIndex.index(forOutputSeconds: 3.0, keptRanges: kept,
                                              samplesPerSecond: 10, sampleCount: 100)
        #expect(index == 50)
    }

    @Test("Past the end of the trimmed timeline there is no sample")
    func pastTheEndIsNil() {
        // Output only runs to 8s. Drawing the last sample in the empty tail
        // would smear the final instant's audio across it.
        #expect(TimelineSampleIndex.index(forOutputSeconds: 9.0, keptRanges: kept,
                                          samplesPerSecond: 10, sampleCount: 100) == nil)
    }

    @Test("A short sample array clamps rather than indexing past its end")
    func shortSampleArrayClamps() {
        // The real case: `peaks` length comes from frames actually read, so a
        // recording whose audio track is a bucket or two shorter than its
        // duration implies is normal. Here 99 samples cover a 10s source that
        // would nominally need 100, and source 9.999s computes index 99 — one
        // past the end. Without the clamp this is an out-of-bounds read in
        // `draw`, which is a crash rather than a wrong pixel.
        //
        // An earlier version of this test used sampleCount: 100 and asserted
        // 99, which the clamp cannot affect — it passed with the clamp removed
        // and proved nothing.
        let index = TimelineSampleIndex.index(forOutputSeconds: 7.999, keptRanges: kept,
                                              samplesPerSecond: 10, sampleCount: 99)
        #expect(index == 98)
    }

    @Test("No samples means no index, rather than a crash")
    func emptySamples() {
        #expect(TimelineSampleIndex.index(forOutputSeconds: 1.0, keptRanges: kept,
                                          samplesPerSecond: 10, sampleCount: 0) == nil)
    }
}
