// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import Testing
@testable import SnittAutomation
@testable import SnittDocument

/// D105: a caller gives the pixels it has, and names the picture they are
/// pixels of.
///
/// Every fixture here uses a 1280 x 800 frame rather than a square one, on
/// purpose. A square frame cannot tell a correct conversion apart from one that
/// divides both axes by the same number, which is the most likely way to get
/// this wrong.
@Suite
struct CoordinateFrameTests {

    /// The rect a `snitt_crop` call maps to, or nil if it does not map at all.
    /// No test here passes `reset`, so nil unambiguously means "refused".
    private func cropRect(_ json: String) -> CropRect? {
        guard case .success(.crop(_, let rect)) = MCPBridge.request(
            forTool: "snitt_crop", arguments: jsonArguments(json)) else { return nil }
        return rect
    }

    // MARK: - snitt_crop

    @Test("A crop given in pixels of a named frame is stored as the right fractions")
    func pixelCropConvertsToFractions() throws {
        // Discriminates against the implementation that declares frameWidth and
        // frameHeight and then ignores them: 320 / 200 / 640 / 400 would reach
        // `CropRect.init`, which CLAMPS into the unit square, and the stored
        // rect would be x 1, y 1, width 0, height 0, a crop with no picture
        // in it, reported as a success.
        let rect = try #require(cropRect(#"""
            {"bundlePath": "/tmp/x.snitt", "x": 320, "y": 200, "width": 640,
             "height": 400, "frameWidth": 1280, "frameHeight": 800}
            """#))
        #expect(abs(rect.x - 0.25) < 1e-9, "x was \(rect.x)")
        // 200 of 800, not 200 of 1280: the axes divide by their own dimension.
        #expect(abs(rect.y - 0.25) < 1e-9, "y was \(rect.y)")
        #expect(abs(rect.width - 0.5) < 1e-9, "width was \(rect.width)")
        #expect(abs(rect.height - 0.5) < 1e-9, "height was \(rect.height)")
    }

    @Test("Fractions still mean fractions when no frame is named")
    func fractionCropIsUnchanged() throws {
        // The control for the test above. Without it, an implementation that
        // divided by something unconditionally could still pass the pixel case.
        let rect = try #require(cropRect(
            #"{"bundlePath": "/tmp/x.snitt", "x": 0.25, "y": 0.25, "width": 0.5, "height": 0.5}"#))
        #expect(rect.x == 0.25)
        #expect(rect.height == 0.5)
    }

    @Test("A crop of the whole frame, in pixels, is accepted rather than refused by a rounding hair")
    func fullFramePixelCropIsAccepted() throws {
        // Guards the epsilon. A bounds check written as `x + width < 1`, or
        // with no tolerance at all, refuses the single most obvious pixel
        // rectangle there is, the whole picture, because 1280 / 1280 is not
        // always exactly 1 once a divide has been through a Double.
        let rect = try #require(cropRect(#"""
            {"bundlePath": "/tmp/x.snitt", "x": 0, "y": 0, "width": 1280,
             "height": 800, "frameWidth": 1280, "frameHeight": 800}
            """#))
        #expect(rect.isFullFrame)
    }

    @Test("A crop that runs off the frame is refused, not quietly pulled back to the edge")
    func overhangingCropIsRefused() {
        // Discriminates against handing the numbers straight to `CropRect.init`,
        // which clamps: x 0.8 with width 0.5 becomes width 0.2 there, and the
        // call SUCCEEDS having cropped 40% of what was asked for and reported a
        // plausible pixel size for it. Clamping is right in the editor, where a
        // drag past the edge means the user wanted the edge; over the API it
        // means the caller measured in a space Snitt was not told about.
        guard case .failure(let error) = MCPBridge.request(
            forTool: "snitt_crop",
            arguments: jsonArguments(
                #"{"bundlePath": "/tmp/x.snitt", "x": 0.8, "y": 0, "width": 0.5, "height": 0.5}"#))
        else { Issue.record("a crop running off the frame must not be clamped into a success"); return }
        #expect(error.message.contains("off the frame"))
    }

    @Test("A pixel crop wider than the frame it names is refused")
    func overhangingPixelCropIsRefused() {
        guard case .failure = MCPBridge.request(
            forTool: "snitt_crop",
            arguments: jsonArguments(#"""
                {"bundlePath": "/tmp/x.snitt", "x": 0, "y": 0, "width": 2000,
                 "height": 400, "frameWidth": 1280, "frameHeight": 800}
                """#))
        else { Issue.record("2000px of a 1280px frame must not be accepted"); return }
    }

    @Test("Half a frame size is refused rather than guessed at")
    func halfAFrameSizeIsRefused() {
        // Discriminates against filling the missing axis in from the one that
        // was given. On this deliberately non-square frame that would divide y
        // by 1280 instead of 800, so a click reported two thirds of the way
        // down the window would land two fifths of the way down: wrong, and
        // wrong silently.
        guard case .failure(let error) = MCPBridge.request(
            forTool: "snitt_crop",
            arguments: jsonArguments(#"""
                {"bundlePath": "/tmp/x.snitt", "x": 320, "y": 200, "width": 640,
                 "height": 400, "frameWidth": 1280}
                """#))
        else { Issue.record("a lone frameWidth must not be accepted"); return }
        #expect(error.message.contains("frameHeight"))
    }

    @Test("A zero frame size is refused rather than dividing by it")
    func zeroFrameSizeIsRefused() {
        // A guard rather than a nicety: 320 / 0 is +infinity, which passes
        // `>= 0` and fails `<= 1`, so without this the caller is told its
        // rectangle runs off the frame, which is true and useless.
        guard case .failure(let error) = MCPBridge.request(
            forTool: "snitt_crop",
            arguments: jsonArguments(#"""
                {"bundlePath": "/tmp/x.snitt", "x": 0, "y": 0, "width": 640,
                 "height": 400, "frameWidth": 0, "frameHeight": 800}
                """#))
        else { Issue.record("a zero frame width must not be divided by"); return }
        #expect(error.message.contains("greater than 0"))
    }

    // MARK: - snitt_report_input

    @Test("A reported click given in pixels is converted against the frame it names")
    func pixelClickConvertsToFractions() throws {
        // Same discrimination as the crop case: an implementation that ignored
        // frameWidth/frameHeight would carry 640 and 320 onto the wire as
        // fractions, and `ClickOverlay` would draw a ring 640 frames' width off
        // the right-hand edge of a video nobody can watch to notice.
        guard case .success(.reportInput(_, _, let x, let y, _)) = MCPBridge.request(
            forTool: "snitt_report_input",
            arguments: jsonArguments(#"""
                {"sessionId": "s1", "kind": "click", "x": 640, "y": 200,
                 "frameWidth": 1280, "frameHeight": 800}
                """#)) else { Issue.record("mapping failed"); return }
        let unitX = try #require(x)
        let unitY = try #require(y)
        #expect(abs(unitX - 0.5) < 1e-9, "x was \(unitX)")
        #expect(abs(unitY - 0.25) < 1e-9, "y was \(unitY)")
    }

    @Test("A reported point outside the window is refused, not pinned to the border")
    func outOfRangeClickIsRefused() {
        // Nothing validated this at all before: 1.5 travelled to the app as a
        // fraction and became a ring drawn off the edge of the picture, or a
        // point the auto-trimmer treated as real. Refusing names the actual
        // mistake: coordinates measured against the whole screen rather than
        // the recorded window.
        guard case .failure(let error) = MCPBridge.request(
            forTool: "snitt_report_input",
            arguments: jsonArguments(
                #"{"sessionId": "s1", "kind": "click", "x": 1.5, "y": 0.5}"#))
        else { Issue.record("a point outside the window must not be accepted"); return }
        #expect(error.message.contains("outside the recorded window"))
    }

    @Test("A keystroke still needs no position, frame or otherwise")
    func keystrokeNeedsNoPosition() {
        // The bounds check runs on x and y together; a version that ran it
        // unconditionally would start refusing every reported keystroke, which
        // is the one kind that legitimately has no position.
        guard case .success(.reportInput(_, _, let x, let y, _)) = MCPBridge.request(
            forTool: "snitt_report_input",
            arguments: jsonArguments(#"{"sessionId": "s1", "kind": "keystroke"}"#))
        else { Issue.record("a keystroke must still map"); return }
        #expect(x == nil)
        #expect(y == nil)
    }

    // MARK: - The two frontends

    @Test("Both frontends convert a pixel crop to the same rect")
    func frontendsAgreeOnAPixelCrop() throws {
        // §4.8: the CLI and the MCP server must be incapable of diverging, and
        // two conversions of the same numbers is exactly how they would. The
        // assertion is on the RECTS, not on both succeeding.
        guard case .success(.crop(_, let cliRect)) = CommandLineParser.parse(
            ["crop", "/tmp/x.snitt", "--x", "320", "--y", "200", "--width", "640",
             "--height", "400", "--frame-width", "1280", "--frame-height", "800"])
        else { Issue.record("the CLI could not express a pixel crop"); return }
        let mcpRect = try #require(cropRect(#"""
            {"bundlePath": "/tmp/x.snitt", "x": 320, "y": 200, "width": 640,
             "height": 400, "frameWidth": 1280, "frameHeight": 800}
            """#))
        let typed = try #require(cliRect)
        #expect(typed == mcpRect)
    }

    @Test("Both frontends convert a pixel click to the same point")
    func frontendsAgreeOnAPixelClick() throws {
        guard case .success(.recordInput(_, _, let cliX, let cliY)) = CommandLineParser.parse(
            ["record", "click", "s1", "640", "200",
             "--frame-width", "1280", "--frame-height", "800"])
        else { Issue.record("the CLI could not express a pixel click"); return }
        guard case .success(.reportInput(_, _, let mcpX, let mcpY, _)) = MCPBridge.request(
            forTool: "snitt_report_input",
            arguments: jsonArguments(#"""
                {"sessionId": "s1", "kind": "click", "x": 640, "y": 200,
                 "frameWidth": 1280, "frameHeight": 800}
                """#)) else { Issue.record("MCP could not express a pixel click"); return }
        #expect(cliX == mcpX)
        #expect(cliY == mcpY)
        let unitX = try #require(cliX)
        #expect(abs(unitX - 0.5) < 1e-9)
    }

    @Test("The CLI refuses a crop that runs off the frame too")
    func cliRefusesAnOverhangingCrop() {
        guard case .failure = CommandLineParser.parse(
            ["crop", "/tmp/x.snitt", "--x", "0.8", "--y", "0", "--width", "0.5", "--height", "0.5"])
        else { Issue.record("the CLI clamped a crop that runs off the frame"); return }
    }

    @Test("The CLI refuses half a frame size too")
    func cliRefusesHalfAFrame() {
        guard case .failure(let failure) = CommandLineParser.parse(
            ["crop", "/tmp/x.snitt", "--x", "320", "--y", "200", "--width", "640",
             "--height", "400", "--frame-width", "1280"])
        else { Issue.record("the CLI accepted a lone --frame-width"); return }
        #expect(failure.message.contains("--frame-height"))
    }
}
