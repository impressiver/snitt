// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit

/// Every editor command that has a key, written down once.
///
/// **The point is that the menu item and the tooltip cannot disagree.** A
/// toolbar button advertising "⌘E" while the menu registers ⌥⌘E is a lie the
/// person finds out about by pressing the key and having nothing happen, and
/// it is the obvious outcome of writing the shortcut twice — once in
/// `NSMenuItem(keyEquivalent:)` and once in a `.help()` string. Both now come
/// from here, and `EditorShortcutTests` asserts they still do.
///
/// `display` is DERIVED rather than typed, for the same reason. A hand-written
/// "⌥⌘T" beside `modifiers: [.command, .option]` is two spellings of one fact,
/// and the whole file exists to stop that.
enum EditorCommand: CaseIterable {
    /// Cut the spans where nothing happens, at the default preset. The toolbar
    /// item offers all three; a key can only mean one, and this is the one the
    /// menu's own "Default" already names.
    case autoTrim
    /// Enter crop mode. Return and Escape then commit or abandon the box, and
    /// those two are NOT here: they are handled by the drag overlay while the
    /// mode is on, because a bare Return registered as a menu key equivalent
    /// would swallow every Return in the app.
    case crop
    /// Put the whole picture back.
    case resetCrop
    /// Show or hide the markers and transcript panel.
    case panel
    /// Write a video file.
    case export

    /// What the toolbar calls it, and the first half of its tooltip.
    var label: String {
        switch self {
        case .autoTrim: return "Auto-Trim"
        case .crop: return "Crop"
        case .resetCrop: return "Reset Crop"
        case .panel: return "Panel"
        case .export: return "Export"
        }
    }

    var key: String {
        switch self {
        case .autoTrim: return "t"
        case .crop: return "c"
        case .resetCrop: return "c"
        case .panel: return "s"
        // Already shipped as ⌘E and stays ⌘E: §15's discipline about public
        // interfaces is about agents, but a key somebody has in their fingers
        // is the same kind of promise.
        case .export: return "e"
        }
    }

    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .autoTrim: return [.command, .option]
        // ⌘C is Copy, so crop takes the option-ed one; reset is the shifted
        // form of crop, which is the platform's own convention for "the
        // opposite of that".
        case .crop: return [.command, .option]
        case .resetCrop: return [.command, .option, .shift]
        // ⌘S is Save. ⌥⌘S for the side panel matches where Finder and Xcode
        // put a sidebar toggle.
        case .panel: return [.command, .option]
        case .export: return [.command]
        }
    }

    /// The shortcut as a person reads it, in Apple's order: ⌃⌥⇧⌘.
    var display: String {
        var glyphs = ""
        if modifiers.contains(.control) { glyphs += "⌃" }
        if modifiers.contains(.option) { glyphs += "⌥" }
        if modifiers.contains(.shift) { glyphs += "⇧" }
        if modifiers.contains(.command) { glyphs += "⌘" }
        return glyphs + key.uppercased()
    }

    /// What a toolbar button says on hover: the name, then the key.
    ///
    /// Deliberately not a sentence. The old tooltips explained the feature
    /// ("Cut the spans where nothing happens"), which is the right text the
    /// first time somebody meets the button and noise every time after — and
    /// none of them said how to do it without the mouse.
    var tooltip: String { "\(label) (\(display))" }
}
