// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import Foundation
import SwiftUI
import SnittDocument
import UniformTypeIdentifiers

/// Accepting a video dropped anywhere on the app.
///
/// **What a drop does today, and what it deliberately does not.** A dropped
/// video opens as its own new document. It does NOT splice into the document
/// already open, because a `.snitt` holds exactly one `capture.mov` and its
/// cuts, markers, transcript, clicks and voiceover are all positions in that
/// one source timeline — 117 places in `Sources/` say so. Inserting a second
/// video needs the document to become an ordered sequence of clips from
/// several assets, which is a different document format rather than a bigger
/// version of this one. Recorded as its own decision rather than half-built.
///
/// Split out from the views so the decision — is this droppable, and what came
/// out of it — is testable without a drag.
@MainActor
enum VideoDropTarget {

    /// What a drag is offering, if Snitt wants it.
    ///
    /// Returns every acceptable video, in the order the drag carried them, so
    /// dropping three files opens three documents rather than silently taking
    /// one. Empty means "not for us", which is what the view turns into a
    /// refused drag rather than a drop that quietly does nothing.
    static func videos(in pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: ImportableMedia.types.map(\.identifier),
        ]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                                options: options) as? [URL]
        else { return [] }
        // The same predicate File ▸ Open and the clipboard use. A drop that
        // accepted something `Open…` refuses is a promise the next step breaks.
        return urls.filter(ImportableMedia.canOpen)
    }

    /// Whether a drag should be accepted at all.
    static func accepts(_ pasteboard: NSPasteboard) -> Bool { !videos(in: pasteboard).isEmpty }
}

/// An `NSView` that takes a video drop and hands it to `onDrop`.
///
/// AppKit rather than SwiftUI's `.onDrop`: the editor's player is already an
/// `NSViewRepresentable` over an `AVPlayerLayer`, and a SwiftUI drop modifier
/// over it competes with the crop overlay for the same gestures. A dedicated
/// view registered for exactly one type does not.
@MainActor
final class VideoDropView: NSView {
    var onDrop: ([URL]) -> Void = { _ in }

    /// Painted while a drag is over the view. A drop target that looks
    /// identical to a view that ignores drags is one nobody discovers.
    private var isHighlighted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard VideoDropTarget.accepts(sender.draggingPasteboard) else { return [] }
        isHighlighted = true
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { isHighlighted = false }
    override func draggingEnded(_ sender: any NSDraggingInfo) { isHighlighted = false }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isHighlighted = false
        let videos = VideoDropTarget.videos(in: sender.draggingPasteboard)
        guard !videos.isEmpty else { return false }
        onDrop(videos)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2),
                                  xRadius: 6, yRadius: 6)
        border.lineWidth = 3
        border.stroke()
    }

    /// Whether this view takes clicks as well as drags.
    ///
    /// False by default, and that is the useful case: the view is stretched
    /// over other controls to catch drags anywhere, and swallowing their
    /// clicks would break them. Drags still arrive either way —
    /// `NSDraggingDestination` is resolved by the registered-type search
    /// rather than by hit-testing.
    var acceptsClicks = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsClicks ? super.hitTest(point) : nil
    }
}

/// The drop view, for SwiftUI.
struct VideoDropOverlay: NSViewRepresentable {
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> VideoDropView {
        let view = VideoDropView(frame: .zero)
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ view: VideoDropView, context: Context) {
        view.onDrop = onDrop
    }
}
