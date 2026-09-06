import AppKit
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
@MainActor
enum DocumentOpener {
    // The project's logger factory — do NOT construct `Logger(subsystem:)`
    // directly. `SnittLog.logger` is the one place that names Snitt's
    // subsystems (M5a), and a hand-rolled Logger would be invisible to
    // `snitt diagnostics export`.
    private static let log = SnittLog.logger(.automation, target: "SnittApp")

    static func open(bundleURL: URL) async throws -> EditorWindowController {
        try await open(bundle: SnittBundle(opening: bundleURL))
    }

    static func open(bundle: SnittBundle) async throws -> EditorWindowController {
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
    }
}
