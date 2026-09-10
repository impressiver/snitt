// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import SwiftUI

/// A draggable divider between two panes.
///
/// Wider than it looks: the visible rule is a hairline, but the target is 8pt,
/// because a 1pt drag target is a target you have to aim at. The same reason
/// the timeline's lanes carry a 24pt floor.
struct ResizableDivider: View {
    /// Which way a rightward drag moves the width — `+1` when the pane being
    /// resized is to the LEFT of the divider, `-1` when it is to the right.
    let direction: Double
    let onDrag: (Double) -> Void
    let onCommit: () -> Void

    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor))
            .frame(width: hovering ? 2 : 1)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onContinuousHover { phase in
                // The cursor is the affordance. Without it the divider is a
                // hairline that happens to respond to dragging, which nobody
                // discovers.
                if case .active = phase { NSCursor.resizeLeftRight.push() }
                else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { onDrag($0.translation.width * direction) }
                    .onEnded { _ in onCommit() })
    }
}
