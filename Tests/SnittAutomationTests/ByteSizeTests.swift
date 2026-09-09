// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
@testable import SnittAutomation

@Test("Plain byte counts parse")
func plainBytes() {
    #expect(ByteSize.parse("1024") == 1024)
    #expect(ByteSize.parse("0") == 0)
}

@Test("Unit suffixes parse case-insensitively")
func unitSuffixes() {
    #expect(ByteSize.parse("10MB") == 10_000_000)
    #expect(ByteSize.parse("10mb") == 10_000_000)
    #expect(ByteSize.parse("500KB") == 500_000)
    #expect(ByteSize.parse("2GB") == 2_000_000_000)
}

@Test("Fractional sizes parse")
func fractionalSizes() {
    #expect(ByteSize.parse("1.5MB") == 1_500_000)
    #expect(ByteSize.parse("0.5KB") == 500)
}

@Test("Whitespace between number and unit is accepted")
func whitespaceAccepted() {
    #expect(ByteSize.parse("10 MB") == 10_000_000)
    #expect(ByteSize.parse("  10MB  ") == 10_000_000)
}

// The discriminating tests. A parser that falls back to a default, or that
// uses Double("...") without validating, passes everything above and fails
// every one of these.
@Test("Malformed input is refused, never defaulted")
func malformedRefused() {
    #expect(ByteSize.parse("") == nil)
    #expect(ByteSize.parse("MB") == nil)
    #expect(ByteSize.parse("ten megabytes") == nil)
    #expect(ByteSize.parse("10XB") == nil)
    #expect(ByteSize.parse("10MB extra") == nil)
    #expect(ByteSize.parse("1.2.3MB") == nil)
}

@Test("Negative, infinite and NaN sizes are refused")
func nonFiniteRefused() {
    // Double("nan") and Double("inf") both SUCCEED in Swift — a parser that
    // forwards Double's result without a finiteness check accepts these and
    // produces a garbage Int conversion, which traps at runtime.
    #expect(ByteSize.parse("-10MB") == nil)

    // Note: "nan", "infMB", and "1e400MB" are rejected by the character-class
    // filter (`n`, `a`, `i`, `f`, `e` are neither digits nor dots) before
    // Double() is reached — they do not test the isFinite guard directly.
    // See intMaxBoundary for tests covering the actual overflow bound.
    #expect(ByteSize.parse("nan") == nil)
    #expect(ByteSize.parse("infMB") == nil)
    #expect(ByteSize.parse("1e400MB") == nil)
}

@Test("Values at and beyond Int.max are refused rather than trapping")
func intMaxBoundary() {
    // Near Int.max, but not exactly. Int.max requires 63 bits, but Double has
    // only 53-bit mantissa. This input rounds to 2^63 - 1024 when parsed as a
    // Double, which fits in Int and should parse, not trap.
    #expect(ByteSize.parse("9223372036854775000") == 9_223_372_036_854_774_784)
    // Well past Int.max, as literal — rounds to 2^63 or beyond.
    #expect(ByteSize.parse("9223372036854775808") == nil)
    // Comfortably past, via a unit multiplier rather than a literal.
    #expect(ByteSize.parse("9999999999GB") == nil)
}
