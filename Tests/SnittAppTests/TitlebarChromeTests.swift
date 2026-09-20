// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import AVFoundation
import SnittDocument
import SnittExport
@testable import SnittApp

/// The editor window's titlebar, which is a real `NSToolbar` now (D97).
///
/// **What these tests used to guard, and why that is gone.** The chrome was a
/// hand-built `HStack` under a transparent `.fullSizeContentView` titlebar, and
/// the named risk was DRAGGING: a titlebar you cannot grab makes the whole
/// arrangement feel broken, and it fails silently — nothing errors, the window
/// just stops moving. Two tests pinned `mouseDownCanMoveWindow` on the hosting
/// view to catch that.
///
/// A real titlebar drags because it is a titlebar. The risk did not move, it
/// stopped existing, so the assertions retire with the row they guarded rather
/// than being rewritten into something that looks like them. What replaces
/// them is the opposite question: whether the window is still configured to
/// let the system draw that titlebar at all.
@Suite(.serialized)
@MainActor
struct TitlebarChromeTests {
    init() { _ = NSApplication.shared }

    private func window(title: String = "single-row") -> NSWindow {
        EditorWindowController.makeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 731), title: title)
    }

    @Test("The window wears one compact row, drawn by the system")
    func windowIsOneCompactRow() async throws {
        // WRONG IMPLEMENTATION: building the toolbar and never setting
        // `toolbarStyle`, which leaves the system default — a TALL unified bar
        // on a document window. Every item would work and the row would be
        // half again as deep as Finder's, which is the entire complaint this
        // change answers.
        let subject = window()
        let chrome = EditorChromeState()
        let state = try await makeState()
        EditorWindowToolbar(state: state, chrome: chrome).install(on: subject)

        #expect(subject.toolbar != nil, "the window has no toolbar — the titlebar is empty")
        #expect(subject.toolbarStyle == .unifiedCompact,
                "the row is not compact; this is the tall unified bar")
    }

    @Test("The title on screen is the title everything else reads")
    func theTitleIsTheSystemsNow() {
        // It used to be `.hidden`, so the app's own row could draw a title
        // without the window drawing a second copy above it. That meant the
        // string Mission Control, the Window menu, ⌘-tab and VoiceOver read was
        // never the string in front of the person, and the two could drift with
        // nothing catching it.
        let subject = window(title: "findable-name")
        #expect(subject.titleVisibility == .visible,
                "the system is not drawing the title, so something else has to")
        #expect(subject.title == "findable-name")
        #expect(!subject.titlebarAppearsTransparent,
                "a transparent titlebar has no material under the toolbar")
    }

    @Test("The content no longer reaches under the titlebar")
    func fullSizeContentViewIsGone() {
        // WRONG IMPLEMENTATION: keeping `.fullSizeContentView` because it was
        // there before and removing a flag feels riskier than leaving it. With
        // a real toolbar it puts the content UNDER the row — the toolbar drawn
        // over the top of the picture rather than above it — and the window
        // still looks broadly right in a screenshot of its lower half.
        #expect(!window().styleMask.contains(.fullSizeContentView),
                "the content is still pulled under the titlebar")
        #expect(!EditorWindowController.usesFullSizeContentView)
    }

    @Test("The window still keeps every style it had before")
    func noStyleWasTradedAway() {
        // A styleMask written as a fresh list is exactly where a resizable
        // window quietly stops being resizable — and this change rewrites that
        // list, which is the one edit that makes this test earn its keep.
        let subject = window()
        for style in [NSWindow.StyleMask.titled, .closable, .resizable, .miniaturizable] {
            #expect(subject.styleMask.contains(style), "the window lost a style it had")
        }
    }

    @Test("Every item the toolbar asks for is one the delegate can build")
    func everyDefaultItemHasAView() async throws {
        // WRONG IMPLEMENTATION: adding an identifier to `defaultItems` and
        // forgetting its `case` in `itemForItemIdentifier`. The delegate
        // returns nil, AppKit drops the item, and a control is simply absent
        // from the window with nothing logged and nothing failing.
        let chrome = EditorChromeState()
        let state = try await makeState()
        let toolbar = EditorWindowToolbar(state: state, chrome: chrome)
        let host = NSToolbar(identifier: "test")

        for identifier in EditorWindowToolbar.defaultItems {
            // The system spacers are AppKit's own and have no case here.
            guard identifier != .flexibleSpace else { continue }
            let item = toolbar.toolbar(host, itemForItemIdentifier: identifier,
                                       willBeInsertedIntoToolbar: true)
            #expect(item != nil, "\(identifier.rawValue) has no item")
            #expect(item?.view != nil, "\(identifier.rawValue) has no view")
            #expect(item?.label.isEmpty == false,
                    "\(identifier.rawValue) has no label, so it is blank in the overflow menu")
        }

        #expect(toolbar.toolbar(host,
                                itemForItemIdentifier: NSToolbarItem.Identifier("nonsense"),
                                willBeInsertedIntoToolbar: true) == nil,
                "an unknown identifier produced an item")
    }

    @Test("The drawer toggle sits apart from the action icons")
    func theDrawerToggleIsItsOwnGroup() {
        // WRONG IMPLEMENTATION: dropping the spacer because removing it moves
        // nothing. This test exists because that was done, on purpose, with a
        // screenshot to justify it.
        //
        // Adjacent toolbar items share ONE capsule and a spacer starts a new
        // one, so the spacer is not spacing here — it is grouping. Without it
        // Auto-Trim, Crop, Export and the panel toggle fuse into a single pill
        // and the drawer toggle stops reading as a different kind of control
        // from the three that change the recording. With it the row draws as
        // two pills, the way Xcode separates its inspector button.
        //
        // The comparison that deleted it asked whether the items had MOVED.
        // They had not: a unified toolbar with a visible title trailing-aligns
        // them either way, same width, same place, same order. Same pixels
        // everywhere except the one rounded rectangle behind them, which was
        // the whole point of the line.
        let items = EditorWindowToolbar.defaultItems
        #expect(items.first == EditorWindowToolbar.Item.agentStatus)
        #expect(items.last == EditorWindowToolbar.Item.panel)

        let space = items.firstIndex(of: .flexibleSpace)
        #expect(space != nil,
                "no spacer: the drawer toggle shares a capsule with the actions")
        let panel = items.firstIndex(of: EditorWindowToolbar.Item.panel)
        #expect(space.flatMap { s in panel.map { $0 == s + 1 } } == true,
                "the spacer is not immediately before the drawer toggle")
        // Nothing else may be split off: one spacer, one seam.
        #expect(items.filter { $0 == .flexibleSpace }.count == 1)
    }

    @Test("Installing the toolbar wires the subtitle through to the window")
    func theSubtitleReachesTheWindow() async throws {
        // WRONG IMPLEMENTATION: setting `window.subtitle` once at init. It
        // counts markers and folds, so it is wrong again the moment anybody
        // marks or cuts — and a subtitle that is merely stale looks exactly
        // like one that is right.
        let subject = window()
        let chrome = EditorChromeState()
        let state = try await makeState()
        EditorWindowToolbar(state: state, chrome: chrome).install(on: subject)

        #expect(chrome.applySubtitle != nil, "nothing is carrying the subtitle to the window")
        chrome.applySubtitle?("3 markers · 1 fold")
        #expect(subject.subtitle == "3 markers · 1 fold")
    }

    @Test("The chrome starts with the rail open and no crop in progress")
    func chromeDefaults() {
        // The rail defaulting open is not arbitrary: the markers list always
        // used to be on screen, and a panel that started hidden would take away
        // a list nobody asked to lose.
        let chrome = EditorChromeState()
        #expect(chrome.showRail)
        #expect(!chrome.croppingActive)
        #expect(chrome.cropBox == .full)
    }

    @Test("The crop item cannot change width, because that is what broke it")
    func cropItemIsFixedWidth() async throws {
        // THE BUG, pinned: a toolbar item takes its width from its view when
        // the item is BUILT, and SwiftUI content growing afterwards does not
        // widen it. A commit button that appeared beside the Crop toggle while
        // the mode was on therefore drew past its own capsule and over the
        // Export icon next door.
        //
        // The fix is that the item's content does not change size, so this
        // measures the view in both crop states and expects one width. A
        // button reintroduced into that item fails here rather than on screen.
        let chrome = EditorChromeState()
        let state = try await makeState()
        let toolbar = EditorWindowToolbar(state: state, chrome: chrome)
        let host = NSToolbar(identifier: "test")

        chrome.croppingActive = false
        let idle = try #require(toolbar.toolbar(
            host, itemForItemIdentifier: EditorWindowToolbar.Item.crop,
            willBeInsertedIntoToolbar: true)?.view)
        idle.layoutSubtreeIfNeeded()
        let idleWidth = idle.intrinsicContentSize.width

        chrome.croppingActive = true
        // A drawn box as well as the mode, since the button that broke this
        // was enabled by one and shown by the other.
        chrome.cropBox = CropRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let cropping = try #require(toolbar.toolbar(
            host, itemForItemIdentifier: EditorWindowToolbar.Item.crop,
            willBeInsertedIntoToolbar: true)?.view)
        cropping.layoutSubtreeIfNeeded()

        #expect(cropping.intrinsicContentSize.width == idleWidth,
                "the crop item changes width with its state, which is the bug")
    }

    @Test("Reset Crop kept a home when it left the titlebar")
    func resetCropIsStillReachable() {
        // WRONG IMPLEMENTATION: deleting the Reset button along with the
        // Apply button, since both were the same rendering problem. That
        // silently removes the only way to undo a crop applied several edits
        // ago — Undo reaches it only by taking everything since along too.
        let titles = AppShell.buildMainMenu().items
            .compactMap(\.submenu)
            .flatMap { $0.items }
            .map(\.title)
        #expect(titles.contains("Reset Crop"),
                "no route to resetting a crop from the menus")
    }

    /// A state over a real, loadable `capture.mov` — the items observe it, so
    /// a stub would not exercise what the delegate actually builds.
    private func makeState() async throws -> EditorTimelineState {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(SnittBundle.fileExtension)
        let bundle = try SnittBundle(creatingAt: url)
        try await writeSyntheticMovie(to: bundle.captureURL, seconds: 2)
        let built = try await CompositionBuilder.build(
            bundle: bundle, edl: EditDecisionList(), scale: 1.0)
        let controller = PreviewController(built: built, jumpPoints: [],
                                           bundle: bundle, scale: 1.0)
        return EditorTimelineState(controller: controller,
                                   edl: EditDecisionList(), events: [])
    }
}
