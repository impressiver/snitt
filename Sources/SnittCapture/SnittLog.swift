import Foundation
import OSLog
import SnittDocument

/// The one place that knows how Snitt names its loggers.
///
/// §12 asks for a subsystem per target and distinguishable error
/// categories. Spike S8 measured that `OSLogStore` exposes exactly
/// `subsystem` and `category`, which is what a diagnostics bundle filters
/// on — so these names are a wire contract, not cosmetics. A module that
/// invents its own root vanishes from every exported bundle while still
/// looking correct in the console.
public enum SnittLog {
    public static let subsystem = "com.impressiver.snitt"

    public static func subsystemName(for target: String) -> String {
        "\(subsystem).\(target)"
    }

    public static func logger(_ category: DiagnosticCategory, target: String) -> Logger {
        Logger(subsystem: subsystemName(for: target), category: category.rawValue)
    }
}
