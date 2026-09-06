import Foundation

/// Decides what a Dock-icon click (`AppDelegate.applicationShouldHandleReopen`)
/// should do once AppKit has already told us there are no visible windows.
///
/// Kept as a pure decision — no `NSAlert`, no `DocumentOpener` — so it can
/// be unit tested without invoking a real `NSAlert.runModal()` (which blocks
/// on user input and would hang a headless test run) or needing a real
/// `.snitt` bundle on disk. `AppDelegate` supplies the real `open` and
/// `explainNoRecents` closures; tests supply recording ones.
///
/// Under Task 1's permanent `.regular` policy the Dock icon survives the
/// last editor window closing, so once introduced, this is what stands
/// between a Dock click and doing nothing — the most common macOS
/// "bring it back" gesture landing as a dead click.
enum DockReopen {
    /// `recentURLs` is expected most-recent-first (as
    /// `NSDocumentController.recentDocumentURLs` returns it) — only the
    /// first is used. Calls exactly one of `open` or `explainNoRecents`,
    /// never both and never neither, so a caller can never end up doing
    /// nothing silently.
    static func handle(
        recentURLs: [URL],
        open: (URL) -> Void,
        explainNoRecents: () -> Void
    ) {
        guard let mostRecent = recentURLs.first else {
            explainNoRecents()
            return
        }
        open(mostRecent)
    }
}
