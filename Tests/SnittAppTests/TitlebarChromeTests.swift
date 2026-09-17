// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import SwiftUI
@testable import SnittApp

/// The editor window's single deck of chrome (rev 5, W3).
///
/// The window used to carry a titlebar AND a toolbar row underneath it — two
/// decks, the upper one containing only a title the lower one already showed.
/// `.fullSizeContentView` with a transparent, hidden-title titlebar makes the
/// toolbar row *be* the titlebar.
///
/// **The risk this item was fenced for is dragging**, and it is the one thing
/// here that a passing suite could not previously have told you about: a
/// titlebar you cannot grab makes the whole arrangement feel broken, and it
/// fails silently — nothing errors, the window just stops moving. So the drag
/// affordance gets a real assertion rather than a comment.
@Suite(.serialized)
@MainActor
struct TitlebarChromeTests {
    init() { _ = NSApplication.shared }

    private func toolbar() -> EditorToolbar {
        EditorToolbar(title: "onboarding-demo",
                      subtitle: "3 marks · 2 cuts · 0:26",
                      croppingActive: .constant(false),
                      showTranscript: .constant(false),
                      hasTranscript: true,
                      canApplyCrop: false,
                      hasCrop: false,
                      trimCaption: nil,
                      onAutoTrim: { _ in },
                      onApplyCrop: {},
                      onResetCrop: {},
                      onExport: {})
    }

    /// The toolbar hosted IN A WINDOW, because that is the only place it is
    /// ever hit-tested.
    ///
    /// On macOS 27 `NSHostingView.hitTest` returns nil for a view that has no
    /// window — and these tests hosted one in mid-air, so both of them started
    /// failing while the real title bar was fine. Measured directly: the same
    /// view added to an `NSWindow` hit-tests to itself and answers
    /// `mouseDownCanMoveWindow == true`, which is exactly what they assert.
    ///
    /// So the harness was asking about a view in a state the app never puts it
    /// in. A window costs one line and makes the question the real one; the
    /// window is returned so the caller can keep it alive, since a deallocated
    /// window takes the view's `window` back to nil and the failure returns
    /// wearing a different hat.
    private func hosted(width: Double = 900) -> (view: NSHostingView<EditorToolbar>,
                                                 window: NSWindow) {
        let host = NSHostingView(rootView: toolbar())
        let frame = NSRect(x: 0, y: 0, width: width, height: EditorToolbar.height)
        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = frame
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    @Test("The chrome row lets a press become a window drag")
    func chromeRowCanMoveTheWindow() {
        // THE named risk for this item, pinned instead of hoped for — and the
        // first version of this test asserted the wrong thing, which is worth
        // recording because it was wrong in a plausible way.
        //
        // It asserted `hitTest` returned nil for the empty middle of the row,
        // on the theory that a press has to miss the content to reach the
        // window. `NSHostingView` returns itself for every point inside its
        // bounds, so that could never hold — and making the SwiftUI background
        // non-hit-testing did not change it, because hit-testing is not the
        // mechanism.
        //
        // AppKit decides by asking the hit view whether a press there may move
        // the window. `NSHostingView` already answers true, so dragging works
        // with no arrangement on our side. What is worth pinning is that
        // answer: wrap this row in a custom `NSView` some day, inherit the
        // default of false, and the window silently stops moving from its own
        // titlebar with nothing failing anywhere.
        let (host, window) = hosted()
        defer { withExtendedLifetime(window) {} }
        let empty = NSPoint(x: 420, y: EditorToolbar.height / 2)
        // `hitTest` already returns `NSView?`, so the old `as? NSView` was a
        // downcast to the type it was — and now that the gate builds with
        // warnings as errors, saying so is a build failure rather than a note.
        let hit = host.hitTest(empty)
        #expect(hit?.mouseDownCanMoveWindow == true,
                "a press in the chrome row cannot move the window — it is not draggable")
    }

    @Test("The controls in that row still take their own clicks")
    func controlsStillRespond() {
        // The other half: the row has to stay interactive. A version of this
        // that made the whole row transparent to clicks would give a draggable
        // window whose Export button does nothing.
        let (host, window) = hosted()
        defer { withExtendedLifetime(window) {} }
        let overControls = NSPoint(x: 860, y: EditorToolbar.height / 2)
        #expect(host.hitTest(overControls) != nil,
                "the trailing controls stopped taking clicks")
    }

    @Test("The toolbar clears the traffic lights")
    func toolbarClearsTheTrafficLights() {
        // Without the inset the document title sits underneath the close,
        // minimise and zoom buttons, which are drawn by the window over the
        // top of this row rather than beside it.
        #expect(EditorToolbar.trafficLightInset >= 78)
    }

    @Test("The window draws its content under the titlebar and hides the title text")
    func windowIsSingleDeck() {
        let window = EditorWindowController.makeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 731),
            title: "single-deck")
        #expect(window.styleMask.contains(.fullSizeContentView),
                "the content does not reach under the titlebar — there are still two decks")
        #expect(window.titlebarAppearsTransparent,
                "an opaque titlebar draws its own strip over the chrome row")
        #expect(window.titleVisibility == .hidden,
                "the title text is still drawn, on top of the row that already shows it")
    }

    @Test("Hidden is not empty — the window still has a title everything else reads")
    func titleSurvivesBeingHidden() {
        // Mission Control, the Window menu, ⌘-tab and VoiceOver all read
        // `title`. Clearing it instead of hiding it makes the window findable
        // by none of them, and looks identical in the one place you are
        // looking when you make the change.
        let window = EditorWindowController.makeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 731),
            title: "findable-name")
        #expect(window.title == "findable-name")
    }

    @Test("The window still keeps every style it had before")
    func noStyleWasTradedAway() {
        // `.fullSizeContentView` is ADDED, not swapped in. A styleMask written
        // as a fresh list is exactly where a resizable window quietly stops
        // being resizable.
        let window = EditorWindowController.makeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 731), title: "x")
        for style in [NSWindow.StyleMask.titled, .closable, .resizable, .miniaturizable] {
            #expect(window.styleMask.contains(style), "the window lost a style it had")
        }
    }
}
