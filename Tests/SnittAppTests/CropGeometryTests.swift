import Testing
import CoreGraphics
@testable import SnittApp
@testable import SnittDocument

// A drag over the preview becomes a crop.
//
// Every test here uses a view whose aspect ratio DIFFERS from the video's,
// because that is the only case where the letterbox matters — and a version of
// this that mapped the drag onto the view instead of onto the video would pass
// every test written with matching aspect ratios.
@Suite
struct CropGeometryTests {
    private let video = CGSize(width: 320, height: 240)          // 4:3
    private let wideView = CGRect(x: 0, y: 0, width: 800, height: 300) // 8:3

    @Test("An aspect-fit video is pillarboxed inside a wider view")
    func videoIsPillarboxed() {
        let rect = CropGeometry.videoRect(videoSize: video, in: wideView)
        // 4:3 in an 8:3 box fits by height: 300 tall, 400 wide, centred.
        #expect(rect.height == 300)
        #expect(rect.width == 400)
        #expect(rect.minX == 200)
        #expect(rect.minY == 0)
    }

    @Test("A drag over the right half of the VIDEO is a crop at x = 0.5")
    func dragMapsToVideoNotView() {
        // The video occupies x 200...600. Its right half is x 400...600.
        // Mapped against the VIEW instead, 400...600 would read as x ≈ 0.5
        // width 0.25 — right-looking x, wrong width. The width assertion is
        // what catches it.
        let drag = CGRect(x: 400, y: 0, width: 200, height: 300)
        let crop = CropGeometry.crop(fromDrag: drag, videoSize: video, in: wideView)
        let rect = try! #require(crop)
        #expect(abs(rect.x - 0.5) < 0.001)
        #expect(abs(rect.width - 0.5) < 0.001, "mapped against the view, not the video")
        #expect(abs(rect.height - 1.0) < 0.001)
    }

    @Test("A drag reaching into the letterbox clips to the video")
    func dragClipsToTheVideo() {
        // Dragging from the far left of the view: everything left of x=200 is
        // pillarbox and must not become part of the crop, or the exported
        // frame would gain black bars that were never in the recording.
        let drag = CGRect(x: 0, y: 0, width: 400, height: 300)
        let rect = try! #require(CropGeometry.crop(fromDrag: drag, videoSize: video, in: wideView))
        #expect(abs(rect.x - 0.0) < 0.001)
        #expect(abs(rect.width - 0.5) < 0.001)
    }

    @Test("A drag entirely in the letterbox is not a crop")
    func dragOutsideTheVideoIsNil() {
        // nil means "no crop expressed", which the caller must not confuse
        // with "crop to nothing" — the latter would render a frame with no
        // picture in it.
        let drag = CGRect(x: 0, y: 0, width: 150, height: 300)
        #expect(CropGeometry.crop(fromDrag: drag, videoSize: video, in: wideView) == nil)
    }

    @Test("A click, or a drag of a few pixels, is not a crop")
    func degenerateDragIsNil() {
        let click = CGRect(x: 400, y: 100, width: 0, height: 0)
        #expect(CropGeometry.crop(fromDrag: click, videoSize: video, in: wideView) == nil)
    }

    @Test("A letterboxed video maps the vertical axis the same way")
    func letterboxedVideoMapsVertically() {
        // The transpose of the pillarbox case. A version that special-cased
        // one axis passes everything above and fails here.
        let tallView = CGRect(x: 0, y: 0, width: 320, height: 480)
        let rect = CropGeometry.videoRect(videoSize: video, in: tallView)
        #expect(rect.width == 320 && rect.height == 240)
        #expect(rect.minY == 120)
        let drag = CGRect(x: 0, y: 120, width: 320, height: 120)
        let crop = try! #require(CropGeometry.crop(fromDrag: drag, videoSize: video, in: tallView))
        #expect(abs(crop.y - 0.0) < 0.001)
        #expect(abs(crop.height - 0.5) < 0.001)
    }
}
