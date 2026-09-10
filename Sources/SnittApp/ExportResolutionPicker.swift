// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit
import SnittDocument

/// The resolution menu that rides in the export save panel's accessory slot.
///
/// AppKit rather than SwiftUI because `NSSavePanel.accessoryView` takes an
/// `NSView`, and hosting SwiftUI inside one to draw a popup and two labels
/// would be more machinery than the job needs.
///
/// It owns no export logic: `ExportPreflight` decides what is worth offering
/// and how it is worded, and this reads `selectedResolution` back out. That
/// split is why the interesting parts are testable without a panel.
@MainActor
final class ExportResolutionPicker: NSView {
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let caveat = NSTextField(labelWithString: "")
    private var options: [ExportOption] = []

    /// What the user picked, or `.source` before the estimates land.
    ///
    /// `.source` is the fallback everywhere in this type for one reason: it is
    /// what pressing Export did before this menu existed, so every path that
    /// has no better answer leaves an unchanged gesture producing an unchanged
    /// file.
    var selectedResolution: ExportResolution {
        let index = popup.indexOfSelectedItem
        guard index >= 0, index < options.count else { return .source }
        return options[index].resolution
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 74))
        let label = NSTextField(labelWithString: "Resolution:")
        label.alignment = .right

        // Said before the numbers appear, not after: "Measuring…" with a live
        // popup underneath would invite a choice from an empty menu.
        popup.addItem(withTitle: "Measuring…")
        popup.isEnabled = false

        caveat.stringValue = ExportPreflight.caveat
        caveat.font = .preferredFont(forTextStyle: .caption1)
        caveat.textColor = .secondaryLabelColor
        caveat.lineBreakMode = .byWordWrapping
        caveat.maximumNumberOfLines = 2

        for view in [label, popup, caveat] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: popup.centerYAnchor),
            popup.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            caveat.topAnchor.constraint(equalTo: popup.bottomAnchor, constant: 6),
            caveat.leadingAnchor.constraint(equalTo: popup.leadingAnchor),
            caveat.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            caveat.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Fills the menu once the estimates arrive.
    ///
    /// An empty result leaves the control disabled and says why. The panel
    /// still exports — at `.source` — because a missing estimate is a missing
    /// convenience, not a reason to refuse the export.
    func populate(with options: [ExportOption]) {
        self.options = options
        popup.removeAllItems()
        guard !options.isEmpty else {
            popup.addItem(withTitle: "Source resolution")
            popup.isEnabled = false
            caveat.stringValue = "Sizes could not be measured. Exports at the "
                               + "recording's own resolution."
            return
        }
        for option in options {
            popup.addItem(withTitle: option.menuTitle)
        }
        popup.isEnabled = true
        if let index = options.firstIndex(where: {
            $0.resolution == ExportPreflight.defaultSelection(in: options)?.resolution
        }) {
            popup.selectItem(at: index)
        }
    }

    /// Test seam: the two states a test needs to drive are "measured" and
    /// "could not measure", and both go through `populate`. Reading the
    /// popup's own titles back is what proves the menu shows what
    /// `ExportPreflight` decided rather than a second opinion.
    var menuTitlesForTesting: [String] { popup.itemTitles }
    var isEnabledForTesting: Bool { popup.isEnabled }
    var caveatForTesting: String { caveat.stringValue }
    func selectForTesting(_ index: Int) { popup.selectItem(at: index) }
}
