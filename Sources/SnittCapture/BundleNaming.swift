import Foundation
import SnittDocument

/// Names a bundle after the work it documents (§7).
///
/// "A demo arrives as `feature-branch-a1b2c3.snitt` rather than
/// `Screen Recording 2026-09-02.mov`."
public enum BundleNaming {
    public static func filename(git: GitContext?, timestamp: Int) -> String {
        let parts = [git?.branch, git?.commit]
            .compactMap { $0 }
            .map(sanitize)
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return "Snitt-\(timestamp).snitt" }
        return parts.joined(separator: "-") + ".snitt"
    }

    /// Branch names legitimately contain "/" and ":". The result is appended to
    /// a directory URL, so an unsanitised slash would target a subdirectory that
    /// does not exist rather than naming the bundle.
    private static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }
}
