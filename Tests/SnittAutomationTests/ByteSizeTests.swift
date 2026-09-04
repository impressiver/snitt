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
    #expect(ByteSize.parse("nan") == nil)
    #expect(ByteSize.parse("infMB") == nil)
    #expect(ByteSize.parse("1e400MB") == nil)
}
