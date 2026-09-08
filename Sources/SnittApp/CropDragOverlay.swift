import SwiftUI
import SnittDocument

/// The drag surface for choosing a crop.
///
/// Drawn only while crop mode is on — an always-present overlay would swallow
/// every click meant for the player underneath.
///
/// All the arithmetic lives in `CropGeometry`, which is pure and tested. This
/// view's job is to collect two points and draw a rectangle between them; it
/// deliberately holds no knowledge of letterboxing, aspect ratios, or how a
/// re-crop composes, because none of that can be tested through a SwiftUI
/// gesture.
struct CropDragOverlay: View {
    let videoSize: CGSize
    let onCommit: (CropRect) -> Void

    @State private var start: CGPoint?
    @State private var current: CGPoint?

    private var dragRect: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let video = CropGeometry.videoRect(videoSize: videoSize, in: bounds)
            ZStack(alignment: .topLeading) {
                // Dimming the letterbox as well as the un-selected picture
                // makes the croppable area visible before the first drag —
                // otherwise the pillarbox looks croppable and is not.
                Color.black.opacity(0.35)
                Rectangle()
                    .path(in: video)
                    .fill(Color.white.opacity(0.001))
                if let dragRect {
                    Rectangle()
                        .path(in: dragRect.intersection(video))
                        .fill(Color.white.opacity(0.12))
                    Rectangle()
                        .path(in: dragRect.intersection(video))
                        .stroke(Color.white, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if start == nil { start = value.startLocation }
                        current = value.location
                    }
                    .onEnded { _ in
                        defer { start = nil; current = nil }
                        guard let dragRect,
                              let crop = CropGeometry.crop(fromDrag: dragRect,
                                                           videoSize: videoSize,
                                                           in: bounds)
                        else { return }
                        onCommit(crop)
                    }
            )
        }
    }
}
