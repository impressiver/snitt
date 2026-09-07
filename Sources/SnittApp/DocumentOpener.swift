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

    /// Opens in flight, keyed by the SAME normalized identity
    /// `EditorWindowController.existing(for:)` uses.
    ///
    /// Whole-branch review F3: checking `existing(for:)` before the
    /// composition build was not enough, because a controller only joins the
    /// open registry inside `show()` — after the build. Two opens of one
    /// bundle issued while the first build was in flight both passed the
    /// check and both showed a window: two windows, two EDLs, last-save-wins
    /// — the exact data loss the check exists to prevent, reachable by a
    /// second Finder double-click during a multi-second build. Closing that
    /// window means registering the WORK, not just the finished window, so
    /// there is no moment in which one document has no representative.
    private static var inFlight: [URL: Task<EditorWindowController, Error>] = [:]

    static func open(bundle: SnittBundle) async throws -> EditorWindowController {
        // Before the composition, not after: building it first wastes the
        // work and can leave a half-built preview behind on the reuse path.
        // Two windows on one document means two EDLs over one bundle and
        // whichever saves last wins — data loss, not a cosmetic duplicate.
        if let existing = EditorWindowController.existing(for: bundle.url) {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }
        let key = EditorWindowController.normalizedBundleURL(bundle.url)
        if let running = inFlight[key] {
            // Someone is already building this document. Join that build and
            // focus its window rather than starting a second one — the same
            // outcome the `existing(for:)` branch above gives, one step
            // earlier in the document's life. A failed build is failed for
            // both callers, and each surfaces it on its own path.
            let editor = try await running.value
            editor.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return editor
        }
        let task = Task { @MainActor in try await build(bundle: bundle) }
        inFlight[key] = task
        // Runs after `task.value` resolves, on success and on failure alike:
        // a build that threw must not leave a poisoned entry that every
        // later open of this bundle joins.
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// The absent-vs-unreadable distinction `AutomationHost.readEDL` and
    /// `MovieExporter.readBundleEvents` already draw for the CLI/MCP paths
    /// (§8): a MISSING `edit.json` is legitimate — a fresh recording nobody
    /// has trimmed yet — and defaults to `.fullRange()`, but a file that
    /// EXISTS and fails to decode must be refused, not silently treated as
    /// "nothing was ever cut".
    ///
    /// This was the one remaining `(try? EditDecisionList.read(from:
    /// bundle)) ?? .fullRange()` — the exact collapsing pattern a
    /// whole-branch review already fixed at the CLI's two call sites — left
    /// standing on the GUI's open path. It is now doubly load-bearing
    /// (D60, M5f): a `schemaVersion` newer than this build understands
    /// throws from `EditDecisionList.init(from:)`, and `try?` used to turn
    /// that refusal into a silently empty `EditDecisionList` — opening a
    /// `.snitt` written by a newer Snitt build would show an empty
    /// timeline, and the next autosave would overwrite `edit.json` with
    /// that empty EDL, destroying the newer build's cuts permanently.
    /// Updates are hand-delivered (D54), so an old and a new build
    /// coexisting on one machine is not a hypothetical. Propagating the
    /// error here reaches `build`'s own `catch` below, which logs it and
    /// rethrows to `openURLs`'s `presentOpenFailure` — a visible alert
    /// instead of a silent, unrecoverable loss.
    private static func readEDL(for bundle: SnittBundle) throws -> EditDecisionList {
        guard FileManager.default.fileExists(atPath: bundle.editURL.path) else {
            return .fullRange()
        }
        return try EditDecisionList.read(from: bundle)
    }

    private static func build(bundle: SnittBundle) async throws -> EditorWindowController {
        do {
            let edl = try Self.readEDL(for: bundle)
            let events = try EventLog.read(from: bundle).events
            let built = try await CompositionBuilder.build(bundle: bundle, edl: edl, scale: 1.0)
            let jumpPoints = MarkerJumpPoints.compute(events: events, keptRanges: built.keptRanges)

            let controller = PreviewController(built: built, jumpPoints: jumpPoints,
                                               bundle: bundle, scale: 1.0)
            let editor = EditorWindowController(controller: controller,
                                                title: bundle.url.lastPathComponent,
                                                bundleURL: bundle.url,
                                                edl: edl, events: events)
            editor.show()
            // Recorded only after `show()` succeeds — a document that failed
            // to open does not belong in the recents list.
            RecentDocuments.note(bundle.url)
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
