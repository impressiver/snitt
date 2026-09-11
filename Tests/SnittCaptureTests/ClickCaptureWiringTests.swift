// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import CoreGraphics
import ScreenCaptureKit
@testable import SnittCapture
@testable import SnittDocument

/// That a click's position survives the trip from the event tap into
/// `events.json` (D64).
///
/// `ClickPositionTests` proves the arithmetic and `ClickOverlayTests` proves
/// the drawing; both passed for months while the exported video showed no
/// clicks at all, because nothing connected them. The defect was a dropped
/// argument — the tap read `CGEvent.location` and the callback signature had
/// nowhere to put it — and it is invisible to any test that starts from a
/// `LoggedEvent` that already has coordinates.
struct ClickCaptureWiringTests {

    @Test("A click with a position is logged WITH its coordinates")
    func clickPositionReachesTheLog() async throws {
        // The end the user sees: events.json carries x and y, because that is
        // the only thing `ClickOverlay.marks` will accept.
        let log = SessionEventLog()
        await log.add(at: 1.0, kind: .click, label: nil, x: 0.25, y: 0.75)
        let events = await log.snapshot()
        let click = try #require(events.first)
        #expect(click.x == 0.25)
        #expect(click.y == 0.75)
    }

    @Test("A click with no position is still logged, just without coordinates")
    func positionlessClickIsStillRecorded() async throws {
        // A click outside the recorded window is a real click and belongs in
        // the log — it is what `AutoDeepTrim` reads to decide a moment was
        // busy. Dropping it entirely to avoid a positionless event would make
        // the overlay work by making the trim worse.
        let log = SessionEventLog()
        await log.add(at: 1.0, kind: .click, label: nil, x: nil, y: nil)
        let events = await log.snapshot()
        let click = try #require(events.first)
        #expect(click.kind == .click)
        #expect(click.x == nil)
        #expect(click.y == nil)
    }

    @Test("Only mouse events are clicks — a keystroke must never carry a position")
    func onlyMouseEventsAreClicks() {
        // The tap asks `kind(for:)` first and attaches a location only when the
        // answer is `.click`, so this mapping is what decides which events can
        // ever have coordinates. A mutant that returned `.click` for `.keyDown`
        // would put the mouse's position on every keystroke — coordinates for
        // an event that has none, which reads as data rather than as a bug.
        #expect(InputEventMonitor.kind(for: .leftMouseDown) == .click)
        #expect(InputEventMonitor.kind(for: .rightMouseDown) == .click)
        #expect(InputEventMonitor.kind(for: .keyDown) == .keystroke)
    }

    @Test("A click event contributes its location; a keystroke contributes none")
    func locationIsTakenFromClicksOnly() throws {
        // THE defect, pinned. The tap read `CGEvent.location` and threw it
        // away, and every human recording exported with no clicks drawn for
        // months. The callback needs a live tap and a granted permission, so
        // the decision it makes is extracted here where a synthesised
        // `CGEvent` can reach it.
        let at = CGPoint(x: 640, y: 480)
        let event = try #require(CGEvent(mouseEventSource: nil,
                                         mouseType: .leftMouseDown,
                                         mouseCursorPosition: at,
                                         mouseButton: .left))
        let click = try #require(InputEventMonitor.location(for: .click, in: event))
        #expect(click == at, "the click's location was dropped or replaced")
        // Same event, different kind: the position must come from the KIND's
        // meaning, not from whatever the event happens to carry. A mouse event
        // classified as a keystroke still has a location field.
        #expect(InputEventMonitor.location(for: .keystroke, in: event) == nil)
    }

    @Test("A frame with no screenRect attachment leaves the geometry unset")
    func syntheticFrameHasNoGeometry() throws {
        // Synthetic buffers in this suite carry no attachments, and a click
        // during such a recording must end up positionless rather than mapped
        // against a rectangle somebody invented. The same path covers a real
        // frame that arrives before ScreenCaptureKit reports geometry.
        let buffer = try makeBareSampleBuffer()
        #expect(CaptureSession.contentScreenRect(buffer) == nil)
    }

    @Test("Geometry updates make the SAME click map differently")
    func geometryDrivesTheMapping() throws {
        // The integration the per-frame update exists for, asserted against
        // observable output rather than against "update was called": a window
        // dragged mid-recording changes where later clicks land in the picture.
        let geometry = CapturedContentGeometry()
        let click = CGPoint(x: 500, y: 300)
        // Asserted at the ORIGIN as well: a point far from (0, 0) falls
        // outside any invented default rect too, so it cannot tell "no
        // geometry" apart from "geometry that does not contain this point".
        #expect(geometry.fraction(ofScreenPoint: .zero) == nil,
                "a click before any frame was given a position anyway")
        #expect(geometry.fraction(ofScreenPoint: click) == nil,
                "a click before any frame must have no position")

        geometry.update(screenRect: CGRect(x: 400, y: 200, width: 400, height: 400))
        let mapped = try #require(geometry.fraction(ofScreenPoint: click))
        #expect(abs(mapped.x - 0.25) < 1e-9)
        #expect(abs(mapped.y - 0.25) < 1e-9)
    }

    /// A CMSampleBuffer with no attachment array, standing in for the synthetic
    /// frames the capture tests feed through `CaptureSession`.
    private func makeBareSampleBuffer() throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                            nil, &pixelBuffer)
        let pixels = try #require(pixelBuffer)
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                     imageBuffer: pixels,
                                                     formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                                        presentationTimeStamp: .zero,
                                        decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                           imageBuffer: pixels,
                                           dataReady: true,
                                           makeDataReadyCallback: nil,
                                           refcon: nil,
                                           formatDescription: try #require(format),
                                           sampleTiming: &timing,
                                           sampleBufferOut: &buffer)
        return try #require(buffer)
    }
}
