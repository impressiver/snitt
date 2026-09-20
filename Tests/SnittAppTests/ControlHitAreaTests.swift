// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation

/// Buttons have to answer to a press anywhere inside them.
///
/// **The reported problem: the transport required clicking the glyph.** A
/// `Button` whose label is an `Image` hit-tests against the DRAWN SHAPE, and
/// `.frame(width:height:)` sets layout bounds rather than a hit region — so a
/// 26x22 button responded only to presses that landed on the arrow itself,
/// and the surrounding points did nothing. It looks like a dead button, not a
/// small one.
///
/// `.contentShape(Rectangle())` is the fix, and it is the kind of thing that
/// gets left off the NEXT icon button rather than reintroduced on this one.
/// So this is a guard against the class: every plain or borderless button in
/// the app has to declare a content shape near it.
///
/// **Text-based checks earn their keep here** because the property is about
/// SwiftUI view modifiers, which a hosted `NSView` tree does not expose — the
/// same reason `LicenseHeaderTests` reads files rather than asking the type
/// system. A crude check that runs beats a precise one that cannot.
@Suite
struct ControlHitAreaTests {
    private static let sources = "Sources/SnittApp"

    /// Styles that strip the system's own background, and with it the
    /// rectangular hit area a bordered button gets for free.
    private static let bareStyles = [".buttonStyle(.plain)", ".buttonStyle(.borderless)"]

    @Test("Every bare-styled button declares a content shape")
    func bareButtonsHaveAContentShape() throws {
        let root = URL(fileURLWithPath: Self.sources)
        let files = (FileManager.default.enumerator(atPath: Self.sources)?
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }) ?? []
        #expect(!files.isEmpty, "found no sources to scan, so this asserts nothing")

        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            let lines = text.components(separatedBy: "\n")
            // Anchored on each BUTTON, not on each style. A bare style also
            // appears on containers that merely set a default for the views
            // inside them — `.buttonStyle(.borderless)` on the transport's
            // HStack is one — and anchoring on the style flags those, which is
            // how a guard earns a reputation for crying wolf.
            for (index, line) in lines.enumerated()
            where line.contains("Button(") || line.contains("Button {") {
                let window = lines[index...min(lines.count - 1, index + 14)]
                    .joined(separator: "\n")
                guard Self.bareStyles.contains(where: window.contains) else { continue }
                if !window.contains(".contentShape(") {
                    offenders.append("\(file):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty,
                "these buttons answer only to a press on the glyph: \(offenders)")
    }

    @Test("No tooltip uses an em dash")
    func tooltipsUseParentheses() throws {
        // The house format is `label (how)`. Tooltips were written at several
        // call sites, some with an em dash and some with parentheses, so
        // hovering two controls in one row gave two styles.
        let root = URL(fileURLWithPath: Self.sources)
        let files = (FileManager.default.enumerator(atPath: Self.sources)?
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }) ?? []
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated()
            where line.contains(".help(") && (line.contains("—") || line.contains("–")) {
                offenders.append("\(file):\(index + 1)")
            }
        }
        #expect(offenders.isEmpty, "em dashes in tooltips: \(offenders)")
    }
}
