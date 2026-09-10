// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import SwiftUI
import SnittDocument

/// The adjustable crop box drawn over the preview.
///
/// Drawn only while crop mode is on — an always-present overlay would swallow
/// every click meant for the player underneath.
///
/// The box is *proposed*, not applied: a drag moves and resizes it, and
/// nothing reaches the EDL until the editor's Apply button commits it. The
/// first version applied on mouse-up, which made a crop a single unrepeatable
/// gesture — the only correction available was undo and a second attempt from
/// scratch, and the box you were aiming for was already gone from the screen.
///
/// The proposal lives in the CALLER (`box`), normalized to the picture rather
/// than to the view, for two reasons: the Apply button is in the toolbar and
/// cannot read this view's state, and a window resize must not move a box the
/// user already placed.
///
/// All the arithmetic lives in `CropBox` and `CropGeometry`, which are pure and
/// tested. This view collects gestures and draws; it deliberately holds no
/// knowledge of letterboxing, minimum sizes, or how a re-crop composes, because
/// none of that can be tested through a SwiftUI gesture.
struct CropDragOverlay: View {
    let videoSize: CGSize
    @Binding var box: CropRect

    /// The proposal as it was when the current drag began. SwiftUI reports a
    /// drag's translation from its start point, so every frame must be
    /// computed against the box at that start, not against the live one.
    @State private var dragStartBox: CropRect?
    @State private var activeHandle: CropHandle?
    /// Set instead of `activeHandle` when a drag began off the box: the user
    /// is drawing a replacement rather than adjusting this one.
    @State private var freshStart: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let video = CropGeometry.videoRect(videoSize: videoSize, in: bounds)
            let rect = denormalized(box, in: video)
            ZStack(alignment: .topLeading) {
                // Dim everything OUTSIDE the proposal, including the letterbox
                // — the un-dimmed region is exactly what the export will keep,
                // which is the whole question the box is asking.
                Path { path in
                    path.addRect(bounds)
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

                Rectangle().path(in: rect).stroke(Color.white, lineWidth: 1)
                thirds(in: rect)
                ForEach(Array(CropHandle.allCases.enumerated()), id: \.offset) { _, handle in
                    if let point = handlePoint(handle, in: rect) {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 8, height: 8)
                            .position(point)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(rect: rect, video: video))
        }
    }

    /// Rule-of-thirds guides, at 40% opacity so they read as guidance rather
    /// than as part of the picture.
    private func thirds(in rect: CGRect) -> some View {
        Path { path in
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                let y = rect.minY + rect.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
    }

    private func dragGesture(rect: CGRect, video: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if activeHandle == nil && freshStart == nil {
                    if let handle = CropBox.handle(at: value.startLocation, in: rect) {
                        activeHandle = handle
                        dragStartBox = box
                    } else if video.contains(value.startLocation) {
                        freshStart = value.startLocation
                    } else {
                        // A drag beginning in the letterbox is not a crop
                        // gesture: there is no picture there to keep.
                        return
                    }
                }
                if let activeHandle, let dragStartBox {
                    let start = denormalized(dragStartBox, in: video)
                    box = normalized(
                        CropBox.adjusted(start, handle: activeHandle,
                                         by: value.translation, limit: video),
                        in: video)
                } else if let freshStart,
                          let drawn = CropBox.box(from: freshStart, to: value.location,
                                                  limit: video) {
                    box = normalized(drawn, in: video)
                }
            }
            .onEnded { _ in
                activeHandle = nil
                dragStartBox = nil
                freshStart = nil
            }
    }

    private func handlePoint(_ handle: CropHandle, in rect: CGRect) -> CGPoint? {
        switch handle {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .top:         return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .inside:      return nil  // the interior is a target, not a dot
        }
    }

    private func denormalized(_ crop: CropRect, in video: CGRect) -> CGRect {
        CGRect(x: video.minX + crop.x * video.width,
               y: video.minY + crop.y * video.height,
               width: crop.width * video.width,
               height: crop.height * video.height)
    }

    private func normalized(_ rect: CGRect, in video: CGRect) -> CropRect {
        guard video.width > 0, video.height > 0 else { return .full }
        return CropRect(x: (rect.minX - video.minX) / video.width,
                        y: (rect.minY - video.minY) / video.height,
                        width: rect.width / video.width,
                        height: rect.height / video.height)
    }
}

#if DEBUG
// The handles are the whole control, and their size is a WCAG 2.5.8 claim
// (24pt minimum). Previewed over a stand-in picture rather than a blank pane,
// because a handle that vanishes against content is still a handle nobody can
// grab.
#Preview("Crop overlay") {
    @Previewable @State var box = CropRect(x: 0.12, y: 0.18, width: 0.62, height: 0.55)
    ZStack {
        LinearGradient(colors: [.blue.opacity(0.35), .purple.opacity(0.35)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
        CropDragOverlay(videoSize: CGSize(width: 1512, height: 982), box: $box)
    }
    .frame(width: 640, height: 420)
}

#Preview("Crop overlay — full frame") {
    // The starting state, where all four handles sit on the picture's own
    // edges and are easiest to lose.
    @Previewable @State var box = CropRect(x: 0, y: 0, width: 1, height: 1)
    ZStack {
        Color.gray.opacity(0.4)
        CropDragOverlay(videoSize: CGSize(width: 1512, height: 982), box: $box)
    }
    .frame(width: 640, height: 420)
}
#endif
