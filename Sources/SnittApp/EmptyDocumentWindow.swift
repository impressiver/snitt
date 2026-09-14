// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import Foundation
import SnittDocument

/// The window File ▸ New opens when there is nothing to import yet.
///
/// **Not an `EditorWindowController` with no video in it.** The editor is
/// built around a `PreviewController`, which is built around a composition,
/// which `CompositionBuilder` refuses to make without a video track — so an
/// "empty editor" in that sense is a window whose every control addresses
/// something that does not exist. This is the honest version: a window that
/// does one thing, says so, and becomes a real editor the moment it has a
/// video.
///
/// It closes itself on a successful drop. Leaving it behind would put an empty
/// window beside the editor it just opened, and the person would have to close
/// something they never deliberately made.
@MainActor
final class EmptyDocumentWindow: NSObject, NSWindowDelegate {
    /// Open windows, so `File ▸ New` twice does not stack two identical
    /// prompts — and so one can be found and closed when a drop lands.
    private(set) static var open: [EmptyDocumentWindow] = []

    let window: NSWindow
    private let onVideos: ([URL]) -> Void

    static func show(onVideos: @escaping ([URL]) -> Void, activate: Bool = true) {
        // Reuse rather than stack. Two of these are indistinguishable, so a
        // second ⌘N should bring the first forward, exactly as a second
        // Command-comma focuses the one Settings window.
        if let existing = open.first {
            if activate {
                existing.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        let controller = EmptyDocumentWindow(onVideos: onVideos)
        open.append(controller)
        if activate {
            controller.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Test-only: drops every open window without touching AppKit's close
    /// machinery, which races another suite's real window close.
    static func resetForTesting() { open.removeAll() }

    private init(onVideos: @escaping ([URL]) -> Void) {
        self.onVideos = onVideos
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Untitled"
        // The same over-release trap every other window in this app documents:
        // a programmatically created NSWindow defaults this to true, which
        // frees it out from under the reference held here.
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        window.contentView = makeContent()
        window.center()
    }

    private func makeContent() -> NSView {
        let drop = VideoDropView(frame: .zero)
        drop.onDrop = { [weak self] urls in
            guard let self, !urls.isEmpty else { return }
            self.onVideos(urls)
            self.close()
        }
        drop.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Drop a video here")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString:
            "Or choose one to open. Snitt copies it into a new recording, so "
            + "auto-trim, markers, the transcript and voiceover all work on it. "
            + "The original file is left where it is.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = 380

        let button = NSButton(title: "Choose Video…", target: self,
                              action: #selector(chooseVideo))

        let stack = NSStackView(views: [title, subtitle, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        // The drop view LAST, so it sits above the label and the button and
        // catches drags anywhere in the window — it declines clicks, so the
        // button underneath still works.
        container.addSubview(drop)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            drop.topAnchor.constraint(equalTo: container.topAnchor),
            drop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            drop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            drop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    @objc private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImportableMedia.types
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onVideos([url])
        close()
    }

    private func close() {
        window.orderOut(nil)
        Self.open.removeAll { $0 === self }
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}
