// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import AppKit
import Foundation
@testable import SnittApp
@testable import SnittDocument

/// Expanding and collapsing a fold from the menu and the keyboard.
///
/// Both existed only as a double-click on the fold's line — a gesture nothing
/// announces — so a right-click offered to DESTROY the cut and gave no way to
/// look inside it first.
@Suite(.serialized)
@MainActor
struct FoldMenuTests {
    init() { _ = NSApplication.shared }

    private let width = 600.0

    private func makeView(cut: Cut, expanded: Bool, selected: Bool) -> TimelineView {
        let view = TimelineView(frame: NSRect(x: 0, y: 0, width: width, height: 180))
        view.update(duration: 30, cuts: [cut], markerPoints: [], playhead: 0,
                    expandedCutIDs: expanded ? [cut.id] : [],
                    selectedFoldID: selected ? cut.id : nil)
        return view
    }

    private func menu(for view: TimelineView, cut: Cut) throws -> NSMenu {
        let x = view.xForTesting(outputSeconds: cut.range.start)
        return try #require(view.contextMenu(at: NSPoint(x: x, y: 90)),
                            "no context menu at the fold")
    }

    @Test("A collapsed fold offers Expand; an expanded one offers Collapse")
    func titleFollowsTheState() throws {
        // ONE item whose title follows the state, not two with one disabled.
        // A menu showing "Expand" greyed out beside "Collapse" says less than
        // one showing the single thing that will happen.
        let cut = Cut(range: TimeRange(start: 10, end: 14))

        let collapsed = try menu(for: makeView(cut: cut, expanded: false, selected: false),
                                 cut: cut)
        #expect(collapsed.items.map(\.title).contains("Expand"))
        #expect(!collapsed.items.map(\.title).contains("Collapse"))

        let expanded = try menu(for: makeView(cut: cut, expanded: true, selected: false),
                                cut: cut)
        #expect(expanded.items.map(\.title).contains("Collapse"))
        #expect(!expanded.items.map(\.title).contains("Expand"))
    }

    @Test("The toggle acts on the fold that was right-clicked")
    func toggleCarriesTheFoldsIdentity() throws {
        // By id, not by position or by whatever is selected: the menu is built
        // from a hit test, and acting on "the selected fold" would toggle the
        // wrong one whenever the two differ.
        let cut = Cut(range: TimeRange(start: 10, end: 14))
        let view = makeView(cut: cut, expanded: false, selected: false)
        var toggled: UUID?
        view.onToggleExpansion = { toggled = $0 }

        let item = try #require(try menu(for: view, cut: cut)
            .items.first { $0.title == "Expand" })
        view.handleToggleFoldMenuItem(item)
        #expect(toggled == cut.id)
    }

    @Test("Remove Cut is still there, and below the toggle")
    func removeCutSurvives() throws {
        // Removing a neighbour is one keystroke from removing the item, and
        // the order is the point: looking inside comes before destroying.
        let cut = Cut(range: TimeRange(start: 10, end: 14))
        let items = try menu(for: makeView(cut: cut, expanded: false, selected: false),
                             cut: cut).items.map(\.title)
        let toggle = try #require(items.firstIndex(of: "Expand"))
        let remove = try #require(items.firstIndex(of: "Remove Cut"))
        #expect(toggle < remove)
    }

    // MARK: - Escape

    @Test("Escape collapses a fold that is selected AND expanded")
    func escapeCollapsesTheSelectedFold() throws {
        let cut = Cut(range: TimeRange(start: 10, end: 14))
        let view = makeView(cut: cut, expanded: true, selected: true)
        var toggled: UUID?
        view.onToggleExpansion = { toggled = $0 }

        view.keyDown(with: .syntheticKey("\u{1B}"))
        #expect(toggled == cut.id)
    }

    @Test("Escape does nothing to a COLLAPSED selected fold")
    func escapeDoesNotExpand() throws {
        // Escape means "put that back". Toggling a collapsed fold would OPEN
        // it, which is the opposite — and a key that does the reverse of what
        // it means is worse than one that does nothing.
        let cut = Cut(range: TimeRange(start: 10, end: 14))
        let view = makeView(cut: cut, expanded: false, selected: true)
        var toggled: UUID?
        view.onToggleExpansion = { toggled = $0 }

        view.keyDown(with: .syntheticKey("\u{1B}"))
        #expect(toggled == nil)
    }

    @Test("Escape with nothing selected is left alone")
    func escapeWithoutASelectionFallsThrough() throws {
        // Swallowed, it would stop Escape dismissing whatever else is on
        // screen. The timeline only claims the key in the one state where it
        // has something to say.
        let cut = Cut(range: TimeRange(start: 10, end: 14))
        let view = makeView(cut: cut, expanded: true, selected: false)
        var toggled: UUID?
        view.onToggleExpansion = { toggled = $0 }

        view.keyDown(with: .syntheticKey("\u{1B}"))
        #expect(toggled == nil)
    }
}
