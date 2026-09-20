// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit

/// One editor shortcut: what it does, which key reaches it, and where it
/// appears in the menus.
public struct KeyboardShortcut: Equatable, Sendable {
    /// The menu item's title, and the name shown in the shortcuts help.
    public let title: String
    /// The key equivalent. Lower-case letters, or a control character.
    public let key: String
    /// Empty for a BARE key — space, Home, an arrow with no ⌘. `Cut Selection`
    /// already ships one of these; see `AppShell` for why it needs
    /// `NSMenuItemValidation` to stay scoped.
    public let modifiers: NSEvent.ModifierFlags
    /// Which menu it belongs under.
    public let menu: Menu
    public let selector: Selector
    /// Draws a separator above this item.
    ///
    /// Here rather than in the menu builder so grouping stays a property of
    /// the list — the same reason the bindings are. A builder that inserted
    /// separators by position would have to be edited every time the list is
    /// reordered, and would silently put the line in the wrong place if that
    /// edit were missed.
    public var startsGroup: Bool = false

    public enum Menu: String, CaseIterable, Sendable {
        case file = "File"
        case edit = "Edit"
        case view = "View"
        case playback = "Playback"
    }
}

/// The one list that both installs the shortcuts and documents them (D84).
///
/// The point is not tidiness. A help dialog written by hand beside a menu
/// built by hand is two descriptions of one behaviour, and they drift — the
/// class `ServerInstructionsTests` exists to catch on the agent surface, where
/// the instructions had already drifted from the tools they described. Here it
/// is cheaper to prevent than to detect: **`shortcuts` is the only place a
/// binding is written down**, `installPlaybackMenu` builds menu items from it,
/// and `helpText` renders the same array. A shortcut that is not in the list
/// exists in neither place, and one that is appears in both or in neither.
///
/// Bare keys are deliberate and already precedented. Space is "also a
/// character", which is the trap D84 named — and the answer already ships:
/// `keyEquivalentModifierMask = []` makes the bare key match, and
/// `AppDelegate`'s `NSMenuItemValidation` conformance is what stops it
/// swallowing that key app-wide. This reuses both rather than inventing a
/// third mechanism.
@MainActor
public enum KeyboardShortcutRegistry {

    /// Named once so the menu and its tests cannot disagree about the wording.
    public static let showClicksTitle = "Show Clicks"
    public static let showSubtitlesTitle = "Show Subtitles"
    public static let showMarkersTitle = "Show Markers"
    /// One title for both states. The item TOGGLES, and two titles would need
    /// two bindings — which is how a menu ends up offering "Over-dub"
    /// while one is already recording.
    public static let overdubTitle = "Over-dub"
    public static let autoTrimTitle = "Auto-Trim"
    public static let cropTitle = "Crop"
    public static let resetCropTitle = "Reset Crop"
    public static let panelTitle = "Panel"
    /// File ▸ Export… — in the registry so the titlebar's Export button can
    /// read its key from the same place as every other button, even though
    /// the File menu builds that item itself.
    public static let exportTitle = "Export…"
    public static let cutSelectionTitle = "Cut Selection"
    public static let addMarkerTitle = "Add Marker"
    public static let addNarrationTitle = "Add Narration"
    public static let zoomInTitle = "Zoom In"
    public static let zoomOutTitle = "Zoom Out"
    public static let stopOverdubTitle = "Stop Over-dubbing"

    public static let shortcuts: [KeyboardShortcut] = [
        .init(title: "Play / Pause", key: " ", modifiers: [], menu: .playback,
              selector: #selector(AppDelegate.togglePlayback(_:))),
        .init(title: "Back to Start", key: "\u{1}", modifiers: [], menu: .playback,
              selector: #selector(AppDelegate.rewindToStart(_:))),
        .init(title: "Previous Mark", key: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
              modifiers: [.option], menu: .playback,
              selector: #selector(AppDelegate.goToPreviousMark(_:))),
        .init(title: "Next Mark", key: String(UnicodeScalar(NSRightArrowFunctionKey)!),
              modifiers: [.option], menu: .playback,
              selector: #selector(AppDelegate.goToNextMark(_:))),
        // ⇧⌘C — C for clicks. Plain ⌘C is Copy and ⇧⌘C is unclaimed, both
        // here and by the system. Grouped away from the four above because it
        // changes what you SEE rather than where you are.
        .init(title: showClicksTitle, key: "c",
              modifiers: [.command, .shift], menu: .playback,
              selector: #selector(AppDelegate.toggleShowClicks(_:)),
              startsGroup: true),
        // ⇧⌘S and ⇧⌘M, beside Show Clicks because they are the same kind of
        // thing: what is drawn OVER the recording. Plain ⌘S and ⌘M are Save
        // and Minimize; the shifted forms are unclaimed, and
        // `shortcutsDoNotCollide` is what proves that rather than this comment.
        .init(title: showSubtitlesTitle, key: "s",
              modifiers: [.command, .shift], menu: .playback,
              selector: #selector(AppDelegate.toggleShowSubtitles(_:))),
        .init(title: showMarkersTitle, key: "m",
              modifiers: [.command, .shift], menu: .playback,
              selector: #selector(AppDelegate.toggleShowMarkers(_:))),
    ]

    /// Edit — the commands that CHANGE the recording.
    ///
    /// Over-dub sits here rather than under Playback, where it shipped. It
    /// records a take into the document, which is an edit; Playback is where
    /// you are in the recording and what is drawn over it. Being one menu away
    /// from Undo is the useful adjacency, because that is what a take you did
    /// not want needs next.
    public static let editShortcuts: [KeyboardShortcut] = [
        // ⌥⌘T. Plain ⌘T is unclaimed here but belongs to the system's font
        // panel by convention, so the option-ed form is the safe one. The
        // titlebar's Auto-Trim offers three presets and a key can only mean
        // one: this is Default, which is the preset that menu already names.
        .init(title: autoTrimTitle, key: "t",
              modifiers: [.command, .option], menu: .edit,
              selector: #selector(AppDelegate.autoTrimDocument(_:))),
        // ⌥⌘C and its shifted form. Plain ⌘C is Copy and ⇧⌘C is Show Clicks,
        // so crop takes the option-ed one and reset takes the shifted form of
        // that — the platform's own way of writing "the opposite of this".
        //
        // Return and Escape commit and abandon the box and are NOT here: the
        // drag overlay handles them while the mode is on, and a bare Return
        // registered as a menu key equivalent would swallow every Return in
        // the app.
        .init(title: cropTitle, key: "c",
              modifiers: [.command, .option], menu: .edit,
              selector: #selector(AppDelegate.toggleCrop(_:))),
        .init(title: resetCropTitle, key: "c",
              modifiers: [.command, .option, .shift], menu: .edit,
              selector: #selector(AppDelegate.resetCrop(_:))),
        // D102, moved out of Playback. Its own group: the two above change the
        // picture, this one records audio into the document.
        .init(title: overdubTitle, key: "v",
              modifiers: [.command, .shift], menu: .edit,
              selector: #selector(AppDelegate.toggleVoiceover(_:)),
              startsGroup: true),
        // ⌥⌘M and ⌥⌘N. ⇧⌘M is Show Markers and ⇧⌘N is New from Clipboard, so
        // both take the option-ed form. Their own group: the three above
        // change the recording that exists, these two put something new in it.
        .init(title: addMarkerTitle, key: "m",
              modifiers: [.command, .option], menu: .edit,
              selector: #selector(AppDelegate.addMarker(_:)),
              startsGroup: true),
        .init(title: addNarrationTitle, key: "n",
              modifiers: [.command, .option], menu: .edit,
              selector: #selector(AppDelegate.addNarration(_:))),
    ]

    /// View — what is on screen beside the recording.
    ///
    /// ⌥⌘S because plain ⌘S is Save and ⇧⌘S is Show Subtitles. The panel is
    /// where Finder and Xcode put a sidebar toggle.
    /// Bindings a hand-built menu already owns, recorded but not assembled.
    ///
    /// Recorded here anyway so the titlebar's Export button reads its key from
    /// the same place as every other button, and so Help ▸ Keyboard Shortcuts
    /// lists ⌘E under File where it actually lives. `assembledShortcuts` is
    /// what the menu builders read, and it leaves this out — a second Export…
    /// in the Edit menu would be a duplicate item AND a ⌘E collision.
    public static let handBuiltShortcuts: [KeyboardShortcut] = [
        .init(title: exportTitle, key: "e", modifiers: [.command], menu: .file,
              selector: #selector(AppDelegate.exportDocument(_:))),
        // Bare Delete, and the item's TITLE follows the highlight — it reads
        // "Remove Cut" over a selected fold — which is why `AppShell` builds
        // it by hand. Recorded here so the transport's Cut button can quote
        // the key rather than spelling it out beside the registry that owns
        // every other one.
        .init(title: cutSelectionTitle, key: "\u{8}", modifiers: [], menu: .edit,
              selector: #selector(AppDelegate.cutTimelineSelection(_:))),
    ]

    public static let viewShortcuts: [KeyboardShortcut] = [
        .init(title: panelTitle, key: "s",
              modifiers: [.command, .option], menu: .view,
              selector: #selector(AppDelegate.togglePanel(_:))),
        // ⌘= and ⌘-, which is what every Mac app binds zoom to. `=` rather
        // than `+` because `+` is the shifted key and AppKit matches the
        // unshifted one.
        .init(title: zoomInTitle, key: "=", modifiers: [.command], menu: .view,
              selector: #selector(AppDelegate.zoomTimelineIn(_:)),
              startsGroup: true),
        .init(title: zoomOutTitle, key: "-", modifiers: [.command], menu: .view,
              selector: #selector(AppDelegate.zoomTimelineOut(_:))),
    ]

    /// Every binding, whichever menu it lands in.
    ///
    /// `shortcuts` above is the Playback list and stays named that way because
    /// the menu builder and three tests read it; this is what "the one list"
    /// means now that there are three menus.
    public static var allShortcuts: [KeyboardShortcut] {
        assembledShortcuts + handBuiltShortcuts
    }

    /// The bindings this type turns into menu items. Everything in
    /// `allShortcuts` except the ones a hand-built menu already owns.
    public static var assembledShortcuts: [KeyboardShortcut] {
        shortcuts + editShortcuts + viewShortcuts
    }

    /// Builds a whole menu from the registry, so an item cannot exist without
    /// a binding or a binding without an item.
    public static func menuItem(for menu: KeyboardShortcut.Menu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.rawValue, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: menu.rawValue)
        for entry in items(in: menu) { submenu.addItem(entry) }
        item.submenu = submenu
        return item
    }

    public static func playbackMenuItem() -> NSMenuItem { menuItem(for: .playback) }

    /// The registry's items for one menu, for a menu that is PART hand-built —
    /// Edit already owns Undo, Cut, Paste and the rest from AppKit, and those
    /// have no business in a list about this app's own commands.
    public static func items(in menu: KeyboardShortcut.Menu) -> [NSMenuItem] {
        assembledShortcuts.filter { $0.menu == menu }.flatMap { shortcut -> [NSMenuItem] in
            let entry = NSMenuItem(title: shortcut.title,
                                   action: shortcut.selector,
                                   keyEquivalent: shortcut.key)
            entry.keyEquivalentModifierMask = shortcut.modifiers
            return shortcut.startsGroup ? [.separator(), entry] : [entry]
        }
    }

    /// What Help ▸ Keyboard Shortcuts shows — rendered from the same array the
    /// menu was built from, which is the whole reason this type exists.
    public static var helpText: String {
        KeyboardShortcut.Menu.allCases.compactMap { menu -> String? in
            let rows = allShortcuts.filter { $0.menu == menu }
            guard !rows.isEmpty else { return nil }
            let body = rows
                .map { "  \(display(of: $0))\t\($0.title)" }
                .joined(separator: "\n")
            return "\(menu.rawValue)\n\(body)"
        }.joined(separator: "\n\n")
    }

    /// The rendered key for a titled shortcut, for tooltips beside the
    /// buttons that do the same thing. Empty if nothing claims that title, so
    /// a renamed shortcut leaves a tooltip short rather than showing a stale
    /// key.
    public static func shortcutDisplay(titled title: String) -> String {
        allShortcuts.first { $0.title == title }.map(display) ?? ""
    }

    /// A control's tooltip: what it does, then the key that also does it.
    ///
    /// **One spelling of the format, `label (key)`.** It was written at four
    /// call sites, two of them with an em dash and two with parentheses, so
    /// hovering two buttons in the same row gave two house styles. Here
    /// because this is where the key comes from anyway.
    ///
    /// A title nothing claims renders as the label alone rather than as a
    /// stale key — the degradation `shortcutDisplay(titled:)` documents.
    public static func tooltip(_ label: String, key title: String) -> String {
        let shortcut = shortcutDisplay(titled: title)
        return shortcut.isEmpty ? label : "\(label) (\(shortcut))"
    }

    /// A key rendered the way macOS writes it, so the help reads like the menu
    /// beside it rather than like a source listing.
    public static func display(of shortcut: KeyboardShortcut) -> String {
        var out = ""
        if shortcut.modifiers.contains(.control) { out += "⌃" }
        if shortcut.modifiers.contains(.option) { out += "⌥" }
        if shortcut.modifiers.contains(.shift) { out += "⇧" }
        if shortcut.modifiers.contains(.command) { out += "⌘" }
        return out + keyName(shortcut.key)
    }

    /// Named rather than printed for the keys that have no glyph. A literal
    /// space renders as nothing at all, which is the one binding most worth
    /// documenting.
    static func keyName(_ key: String) -> String {
        switch key {
        case " ": return "Space"
        case "\u{1}": return "Home"
        case "\u{8}", "\u{7f}": return "Delete"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): return "←"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): return "→"
        default: return key.uppercased()
        }
    }
}
