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
    /// Whether THIS divider currently owns a pushed cursor.
    ///
    /// `NSCursor.push()`/`pop()` is a stack, and `onContinuousHover` reports
    /// `.active` on every mouse MOVE, not once on entry — so the old code
    /// pushed the resize cursor dozens of times during a single pass across
    /// the divider and popped it once. The stack never unwound, and the
    /// pointer stayed a resize arrow over the whole window until something
    /// else reset it. Pushing only on the transition is what makes the pair
    /// balance.
    @State private var owningCursor = false

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
                let inside: Bool
                if case .active = phase { inside = true } else { inside = false }
                guard inside != owningCursor else { return }
                owningCursor = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            // A divider can vanish while the pointer is over it — the
            // transcript pane closes, the window resizes past a pane's
            // minimum — and a push with no matching pop leaves the resize
            // cursor on screen with nothing under it to explain why.
            .onDisappear {
                if owningCursor { NSCursor.pop(); owningCursor = false }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { onDrag($0.translation.width * direction) }
                    .onEnded { _ in onCommit() })
    }
}

#if DEBUG
// Both directions, against real surfaces: the divider's whole job is to be
// findable without being loud, and it can only be judged beside the panes it
// separates.
#Preview("Divider") {
    HStack(spacing: 0) {
        Color.gray.opacity(0.12).frame(width: 160)
        ResizableDivider(direction: 1, onDrag: { _ in }, onCommit: {})
        Color.gray.opacity(0.04).frame(width: 260)
        ResizableDivider(direction: -1, onDrag: { _ in }, onCommit: {})
        Color.gray.opacity(0.12).frame(width: 160)
    }
    .frame(height: 240)
}
#endif
