import Foundation
import SnittDocument

/// Names a bundle after the work it documents (§7).
///
/// "A demo arrives as `feature-branch-a1b2c3.snitt` rather than
/// `Screen Recording 2026-09-02.mov`."
public enum BundleNaming {
    /// Keeps room for the ".snitt" extension and any future suffix within
    /// macOS's ~255-byte filename limit. A branch name over this would
    /// otherwise make `SnittBundle(creatingAt:)` throw an obscure filesystem
    /// error instead of a name Snitt could simply have prevented.
    private static let maxAssembledLength = 200

    public static func filename(git: GitContext?, timestamp: Int) -> String {
        let branch = git?.branch.map(sanitize)
        let commit = git?.commit.map(sanitize)

        var parts = [branch, commit].compactMap { $0 }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "Snitt-\(timestamp).snitt" }

        // Truncate the BRANCH half, not the commit: the commit is the more
        // identifying half of the two, and short-circuiting a long branch
        // name still leaves a usable, disambiguating name.
        if parts.count == 2 {
            let commitPart = parts[1]
            // Room for "-<commit>.snitt" plus the joining "-".
            let budget = maxAssembledLength - commitPart.utf8.count - 1
            parts[0] = String(parts[0].prefix(max(0, budget)))
            parts = parts.filter { !$0.isEmpty }
        } else {
            parts[0] = String(parts[0].prefix(maxAssembledLength))
        }

        let assembled = parts.joined(separator: "-")

        // A LEADING dot is stripped separately from the general sanitisation
        // below: dots are fine inside a name ("release.2", "v1.2"), but a
        // branch called ".hidden-wip" would produce a dot-prefixed bundle
        // that Finder and `ls` hide — the CLI would report success, print a
        // path, and the user would see nothing where their recording should
        // be. Applied to the ASSEMBLED name, not per-part, so ".hidden"
        // joined with a commit is still caught.
        //
        // The literal ".." is not a risk here: the commit and ".snitt" are
        // always appended after this strip, so the assembled name can never
        // BE ".." — only ever start with it as a substring, which is exactly
        // what this trims away.
        let unhidden = String(assembled.drop { $0 == "." })

        let name = unhidden.isEmpty ? "Snitt-\(timestamp)" : unhidden
        return name + ".snitt"
    }

    /// Branch names legitimately contain "/" and ":". The result is appended to
    /// a directory URL, so an unsanitised slash would target a subdirectory that
    /// does not exist rather than naming the bundle.
    private static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }
}
