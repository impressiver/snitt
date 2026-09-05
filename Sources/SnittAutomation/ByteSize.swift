import Foundation

/// Parses a human-written size like `10MB` into a byte count.
///
/// Returns `nil` for anything it does not fully understand. It never guesses
/// and never falls back to a default: a `--max-size` that silently became
/// "no limit" would export an oversized file and report success, which is
/// the confidently-wrong failure §8 exists to prevent. Callers turn `nil`
/// into an error naming the offending value.
///
/// Units are decimal (MB = 1,000,000), matching how file-size limits are
/// quoted by the services agents actually hit — GitHub's 10 MB attachment
/// limit is decimal, not 10 MiB.
public enum ByteSize {
    private static let units: [(suffix: String, multiplier: Double)] = [
        // Longest first: "kb" must not match before "k" is ruled out, and
        // "b" must be tried last or it swallows the "B" of "MB".
        ("gb", 1_000_000_000),
        ("mb", 1_000_000),
        ("kb", 1_000),
        ("g", 1_000_000_000),
        ("m", 1_000_000),
        ("k", 1_000),
        ("b", 1),
    ]

    public static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        var number = trimmed
        var multiplier = 1.0
        for unit in units where trimmed.hasSuffix(unit.suffix) {
            number = String(trimmed.dropLast(unit.suffix.count))
            multiplier = unit.multiplier
            break
        }
        number = number.trimmingCharacters(in: .whitespaces)
        guard !number.isEmpty else { return nil }

        // Reject anything that is not digits and at most one dot BEFORE
        // handing it to Double. Double("nan"), Double("inf") and
        // Double("1e400") all succeed, and the last is infinite.
        guard number.allSatisfy({ $0.isNumber || $0 == "." }),
              number.filter({ $0 == "." }).count <= 1,
              let value = Double(number),
              value.isFinite,
              value >= 0
        else { return nil }

        let bytes = value * multiplier
        // `Double(Int.max)` rounds UP to 2^63, so `bytes <= Double(Int.max)`
        // admits a value one greater than Int.max and the conversion below
        // then traps. `Int(exactly:)` on a floored value asks the question
        // that actually matters: does this fit?
        guard let result = Int(exactly: bytes.rounded(.down)) else { return nil }
        return result
    }
}
