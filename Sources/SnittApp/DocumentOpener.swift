import Foundation
import SnittCapture
import SnittDocument
import SnittExport

/// Opens a `.snitt` bundle into an editor window (§4.14).
///
/// This was `RecordingCoordinator.openEditor(for:)` — private, and called
/// from exactly one place: the end of a recording. That is why a bundle
/// could be written and never reopened (D45). Every caller now shares this
/// path: a finished recording, File ▸ Open, Open Recent, and a Finder
/// double-click.
///
/// `@MainActor` here is safe only because `CompositionBuilder.build` is
/// `nonisolated async` under this package's tools-version 6.0: the `await`
/// below hops off the main actor for the actual build work and back for the
/// `EditorWindowController` construction. Under tools-version 6.2+
/// (`NonisolatedNonsendingByDefault`), a `nonisolated async` function
/// without an explicit `nonisolated(nonsending: false)` runs on the
/// caller's actor by default — so this same call would silently keep the
/// whole composition build on the main thread. That is a hang on a long
/// recording, not a compile error, and nothing here would flag it. Whoever
/// bumps the tools version needs to re-check this.
@MainActor
enum DocumentOpener {
    // The project's logger factory — do NOT construct `Logger(subsystem:)`
    // directly. `SnittLog.logger` is the one place that names Snitt's
    // subsystems (M5a), and a hand-rolled Logger would be invisible to
    // `snitt diagnostics export`.
    //
    // This logger exists because `RecordingCoordinator`'s own `.compositor`
    // logger only covers the end-of-recording caller. Tasks 3, 4 and 6 add
    // File ▸ Open, Open Recent, and a Finder double-click, none of which go
    // through `RecordingCoordinator` — without logging here, those callers
    // would fail silently.
    private static let log = SnittLog.logger(.automation, target: "SnittApp")

    static func open(bundleURL: URL) async throws -> EditorWindowController {
        try await open(bundle: SnittBundle(opening: bundleURL))
    }

    static func open(bundle: SnittBundle) async throws -> EditorWindowController {
        do {
            let edl = (try? EditDecisionList.read(from: bundle)) ?? .fullRange()
            let events = try EventLog.read(from: bundle).events
            let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
            let jumpPoints = MarkerJumpPoints.compute(events: events, keptRanges: built.keptRanges)

            let controller = PreviewController(built: built, jumpPoints: jumpPoints,
                                               bundle: bundle, scale: 1.0)
            let editor = EditorWindowController(controller: controller,
                                                title: bundle.url.lastPathComponent,
                                                edl: edl, events: events)
            editor.show()
            return editor
        } catch {
            // Same redaction discipline as `RecordingCoordinator`'s catch
            // (do not simplify either one into interpolating the path or
            // the bundle): the bundle's filename is branch-derived
            // (`BundleNaming`) and this line is collected verbatim into
            // `snitt diagnostics export`. Never `String(describing: error)`
            // either — a Cocoa `NSError` renders `userInfo`, which carries
            // the full absolute path. domain+code+localizedDescription is
            // the diagnostic value without the leak.
            let ns = error as NSError
            log.error("Could not open the editor: \(ns.domain, privacy: .public) \(ns.code, privacy: .public) \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
