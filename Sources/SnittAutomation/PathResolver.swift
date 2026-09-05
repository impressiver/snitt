import Foundation

/// Resolves a client-supplied path against the CALLER's working directory —
/// never the app's.
///
/// Finding #3 of the M3c whole-branch review: `snitt-cli` forwarded
/// `bundlePath`/`outputPath` verbatim, and `AutomationHost` resolved them
/// with `URL(fileURLWithPath:)` against the APP's cwd, not the client's.
/// `snitt export --out demo.mp4` wrote beside wherever Snitt.app happened to
/// launch, and handed back a manifest whose `outputPath` was the bare string
/// `"demo.mp4"` — unresolvable by the agent that asked for it.
///
/// This is pure `String`/`FileManager` work, so it lives here in
/// `SnittAutomation` (dependency on `SnittDocument` only — no new dependency
/// needed) alongside `CommandLineParser`, rather than duplicated inside
/// `snitt-cli`'s `main.swift`, which this milestone's own record shows is
/// exactly the kind of wiring code no test here was watching.
public enum PathResolver {
    /// - `~` is expanded (`NSString.expandingTildeInPath`) BEFORE the
    ///   relative/absolute resolution below, so `~/demo.mp4` lands in the
    ///   user's home directory rather than a literal `~` subdirectory of
    ///   `workingDirectory` — a directory that generally does not exist.
    ///   `URL(fileURLWithPath:)` happens to expand a leading `~` on its own
    ///   too, but that is an internal `NSString` behavior of the initializer
    ///   rather than a documented contract of `URL`; expanding explicitly
    ///   first makes the behavior this function's own, not a side effect of
    ///   an implementation detail one Foundation update away from changing.
    /// - An absolute path (including one that was just tilde-expanded) is
    ///   returned standardized (`.`/`..`/duplicate slashes collapsed) but
    ///   otherwise unchanged; `workingDirectory` plays no part.
    /// - A relative path is resolved against `workingDirectory` (defaulting
    ///   to this process's own cwd) and standardized the same way.
    /// - `workingDirectory` is treated as a DIRECTORY explicitly
    ///   (`isDirectory: true`) rather than left for `URL` to guess from the
    ///   filesystem. Without that hint, `URL(fileURLWithPath:relativeTo:)`
    ///   resolves a relative path as a SIBLING of `workingDirectory` instead
    ///   of a child of it whenever `workingDirectory` does not already exist
    ///   on disk — dropping the last path component entirely. A caller's
    ///   cwd always exists in practice, so this never showed up in ad hoc
    ///   testing, but a synthetic `workingDirectory` in a unit test hits it
    ///   immediately.
    /// - The empty string resolves to `workingDirectory` itself — `URL`'s
    ///   own behavior for a zero-length relative component, pinned by a
    ///   test below rather than left as an accident of Foundation.
    public static func resolve(_ path: String,
                               workingDirectory: String = FileManager.default.currentDirectoryPath) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        return URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL.path
    }
}
