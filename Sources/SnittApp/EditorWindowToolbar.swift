// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import Combine
import SnittDocument
import SwiftUI

/// The chrome's own state: what a control in the titlebar is acting on when
/// the control does not live in the content view any more (D97).
///
/// These three were `@State` inside `EditorContentView`, which is exactly as
/// far as they could stay. An `NSToolbarItem` is AppKit and cannot see a
/// SwiftUI view's private storage, so the toolbar could not read whether crop
/// mode was on, nor turn it off after applying. Hoisting them is most of the
/// cost of this change and the reason D97 called it "not small".
///
/// Still UI-only. Nothing here is ever written into `edl` or reaches disk —
/// the same discipline `expandedCutIDs` and `selection` keep.
@MainActor
final class EditorChromeState: ObservableObject {
    /// Crop is a MODE, so it is a toggle rather than three permanent buttons.
    @Published var croppingActive = false
    /// The crop the box is currently PROPOSING, normalized to the picture on
    /// screen. Read by the toolbar so Apply knows whether it has anything to
    /// apply, written by the drag overlay in the content view.
    @Published var cropBox: CropRect = .full
    /// Whether the side panel is on screen. Defaults to TRUE because the
    /// markers list always used to be.
    @Published var showRail = true

    /// Pushes the document subtitle to the window, which DRAWS it now.
    ///
    /// A closure rather than a window reference, so this stays constructible
    /// in a test without one — and so the only object that knows about the
    /// window is the controller that owns it.
    var applySubtitle: ((String) -> Void)?
}

/// The editor window's titlebar, as a real `NSToolbar` (D97).
///
/// **What this replaces, and why a hand-built row could not get there.** The
/// old chrome was one `HStack` under a transparent `.fullSizeContentView`
/// titlebar. It looked close, and four things it could not do were the whole
/// of the request:
///
/// - **The traffic-light inset.** The row began where the window began, so the
///   first 78 points were dead space the close, minimise and zoom buttons sat
///   in, held clear by a hardcoded `trafficLightInset` that had to be guessed
///   and kept in step with AppKit by hand. A toolbar is laid out beside those
///   buttons by the system, so the constant goes away rather than moving.
/// - **Overflow.** A narrow window clipped controls. A toolbar collects them
///   into a chevron.
/// - **The material, the separator and the scroll-edge effect** the system
///   draws under a real titlebar, which is most of why Finder's single row
///   reads as one surface rather than as a strip of buttons.
/// - **The title itself.** It was drawn by the app, in the app's own fonts,
///   while `titleVisibility` was `.hidden` to stop the system drawing a second
///   copy. Now the window's `title` and `subtitle` are the ones on screen, so
///   what Mission Control, the Window menu and ⌘-tab read is the same string
///   the person is looking at.
///
/// **Items host SwiftUI.** The controls were already written as SwiftUI views
/// and are worth keeping as ones; an `NSToolbarItem` takes any `NSView`, and
/// `NSHostingView` is one. What could NOT come across is the private `@State`
/// they were reading, which is what `EditorChromeState` exists for.
@MainActor
final class EditorWindowToolbar: NSObject, NSToolbarDelegate {
    private let state: EditorTimelineState
    private let chrome: EditorChromeState
    /// Held so its visibility can follow `agentIsDriving`. `isHidden` is the
    /// writable one — `isVisible` reports what the toolbar decided.
    private weak var agentItem: NSToolbarItem?
    private var agentObserver: AnyCancellable?

    init(state: EditorTimelineState, chrome: EditorChromeState) {
        self.state = state
        self.chrome = chrome
        super.init()
    }

    /// Grouped by WHAT A CONTROL ACTS ON, which is the split the old row
    /// already used and the one worth keeping: everything here changes the
    /// document, and the transport that changes the playhead stays at the head
    /// of the timeline where the playhead lives.
    ///
    /// Auto-Trim carries its own outcome caption and Crop carries its own
    /// commit, rather than either being a separate item that appears and
    /// disappears. A toolbar whose item COUNT changes reflows the row, and the
    /// caption exists to be read next to the control that caused it.
    enum Item {
        static let agentStatus = NSToolbarItem.Identifier("snitt.agentStatus")
        static let autoTrim = NSToolbarItem.Identifier("snitt.autoTrim")
        static let crop = NSToolbarItem.Identifier("snitt.crop")
        static let export = NSToolbarItem.Identifier("snitt.export")
        static let panel = NSToolbarItem.Identifier("snitt.panel")
    }

    /// **The `.flexibleSpace` is what separates the drawer toggle from the
    /// actions, and it does it by GROUPING rather than by spacing.** Adjacent
    /// items share one capsule; a spacer starts a new one. So this list draws
    /// as two pills — Auto-Trim, Crop and Export together, then the panel
    /// toggle on its own — which is how Xcode separates its inspector button
    /// from the controls beside it.
    ///
    /// Worth stating because the obvious check misses it. Removing the spacer
    /// moves nothing: a unified toolbar with a visible title gives the title
    /// the leading area and trailing-aligns every item either way, so the row
    /// looks the same width, in the same place, with the same icons in the
    /// same order. What changes is that the four fuse into one pill and the
    /// drawer toggle stops reading as a different kind of control. Checking
    /// that the items had not moved is exactly the check that would delete
    /// this line — and did, once.
    static let defaultItems: [NSToolbarItem.Identifier] = [
        Item.agentStatus, Item.autoTrim, Item.crop, Item.export,
        .flexibleSpace, Item.panel,
    ]

    /// Built here rather than by the caller so the window and its delegate
    /// cannot be wired up two different ways.
    func install(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "snitt.editor")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        // The whole point of the request: ONE compact row, the way Finder and
        // Xcode wear it, rather than a tall unified bar.
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
        chrome.applySubtitle = { [weak window] subtitle in window?.subtitle = subtitle }
        chrome.applySubtitle?(state.documentSubtitle)
        // The badge appears and disappears while the window is open, so its
        // visibility has to follow rather than be set once at build time.
        agentObserver = state.$agentIsDriving.sink { [weak self] driving in
            self?.agentItem?.isHidden = !driving
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItems
    }

    /// The same list: these are the editor's verbs, not a palette to arrange.
    /// Offering customisation would let someone remove Export from the only
    /// place it appears.
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.defaultItems
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Item.agentStatus:
            let item = hosting(identifier, label: "Agent",
                               AgentStatusToolbarItem(state: state))
            // A SwiftUI view that renders nothing still leaves the item's own
            // padding behind, and that gap sits at the LEADING edge of the
            // capsule where it reads as a layout mistake rather than as a
            // space reserved for something. `isVisible` takes the item out of
            // the row entirely.
            item.isHidden = !state.agentIsDriving
            agentItem = item
            return item
        case Item.autoTrim:
            return hosting(identifier, label: "Auto-Trim",
                           AutoTrimToolbarItem(state: state))
        case Item.crop:
            return hosting(identifier, label: "Crop",
                           CropToolbarItem(chrome: chrome))
        case Item.export:
            return hosting(identifier, label: "Export",
                           ExportToolbarItem(state: state))
        case Item.panel:
            return hosting(identifier, label: "Panel",
                           PanelToolbarItem(state: state, chrome: chrome))
        default:
            return nil
        }
    }

    /// One `NSToolbarItem` around one SwiftUI view.
    ///
    /// `NSHostingView` reports an intrinsic content size, which is what lets a
    /// toolbar item size itself to a control whose width depends on its label
    /// — and `sizingOptions` keeps that size current when the label changes,
    /// which Crop's does every time the mode is toggled.
    private func hosting(_ identifier: NSToolbarItem.Identifier,
                         label: String,
                         _ view: some View) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = [.intrinsicContentSize]
        item.view = host
        // Read by the overflow menu and by VoiceOver. An item with no label is
        // one that disappears into the chevron as a blank row.
        item.label = label
        item.paletteLabel = label
        return item
    }
}

// MARK: - The items

/// D109's "Agent editing" badge, which used to sit beside the document name.
///
/// It stays at the LEADING edge, first among the items and so immediately
/// after the title the system draws — because it is a fact about the document
/// in front of you, and status stranded at the far end of a row reads as
/// unrelated.
///
/// Taken out of the row entirely when no agent is driving, via the item's
/// `isHidden`. Rendering an empty SwiftUI view instead was tried and looked
/// wrong: the item keeps its own padding, and that gap lands at the LEADING
/// edge of the capsule, where an unexplained space reads as a layout mistake
/// rather than as room held for something.
private struct AgentStatusToolbarItem: View {
    @ObservedObject var state: EditorTimelineState

    var body: some View {
        if state.agentIsDriving {
            Label("Agent editing", systemImage: "wand.and.rays")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .accessibilityLabel("An agent is editing this recording")
                .fixedSize()
                .transition(.opacity)
        }
    }
}

/// Auto-Trim, with the outcome caption beside it.
///
/// One item rather than two, so the caption cannot be stranded at the far end
/// of the row reading as unrelated status, and so its arrival does not change
/// how many items the toolbar has.
private struct AutoTrimToolbarItem: View {
    @ObservedObject var state: EditorTimelineState

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Conservative") { state.autoDeepTrim(preset: .conservative) }
                Button("Default") { state.autoDeepTrim(preset: .default) }
                Button("Aggressive") { state.autoDeepTrim(preset: .aggressive) }
            } label: {
                Label("Auto-Trim", systemImage: "wand.and.stars")
            }
            .menuStyle(.button)
            .fixedSize()
            .help(EditorCommand.autoTrim.tooltip)

            if let caption = state.lastTrimOutcome.map(EditorContentView.trimCaption) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .fixedSize()
            }
        }
    }
}

/// Crop mode. One toggle, and nothing that appears beside it.
///
/// **A commit button used to live here and it rendered wrong.** A toolbar item
/// takes its width from its view when the item is built; the SwiftUI content
/// growing afterwards does not widen the item, so "Apply" drew past the end of
/// its own capsule and over the Export icon next door. That is a property of
/// items whose content changes size, not of that one button — so the fix is
/// that this item's content does not change size.
///
/// Return applies the crop and Escape leaves the mode, handled by the drag
/// overlay in `EditorContentView` — which is on screen exactly while the mode
/// is, so the keys cannot fire when there is nothing to apply them to.
private struct CropToolbarItem: View {
    @ObservedObject var chrome: EditorChromeState

    var body: some View {
        Toggle(isOn: $chrome.croppingActive) {
            Label("Crop", systemImage: "crop")
        }
        .toggleStyle(.button)
        .fixedSize()
        .help(EditorCommand.crop.tooltip)
    }
}

/// The one accent-coloured control, because it is the only thing here that
/// ends the session.
///
/// No `keyboardShortcut` of its own: ⌘E is File ▸ Export…, which raises the
/// same sheet. A shortcut declared inside a toolbar item's hosting view would
/// be a second registration for one key, in a view outside the content
/// hierarchy the responder chain walks.
private struct ExportToolbarItem: View {
    @ObservedObject var state: EditorTimelineState

    var body: some View {
        Button { state.requestExport() } label: {
            Label("Export…", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.borderedProminent)
        .fixedSize()
        .help(EditorCommand.export.tooltip)
    }
}

/// The panel toggle, last in the row and in a capsule of its own — where every
/// Mac app puts its inspector toggle, and where being there is most of what
/// says what it does.
///
/// The spacer before it in `defaultItems` is what buys the separate capsule;
/// see that list's note.
private struct PanelToolbarItem: View {
    @ObservedObject var state: EditorTimelineState
    @ObservedObject var chrome: EditorChromeState

    var body: some View {
        Toggle(isOn: $chrome.showRail) {
            Label("Panel", systemImage: "sidebar.trailing")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .fixedSize()
        .disabled(state.transcriptionStatus == .none)
        .help(EditorCommand.panel.tooltip)
        .accessibilityLabel("Markers and transcript panel")
        .accessibilityAddTraits(chrome.showRail ? [.isSelected] : [])
    }
}
