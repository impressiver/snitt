// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import SwiftUI

/// One collapsible section of the editor's side panel.
///
/// **Independently expandable, deliberately.** The two sections are both
/// indexes of the same recording and are read TOGETHER — a marker says where
/// something happened and the transcript says what was said there. An
/// accordion that closed one to open the other would make comparing them a
/// pair of clicks, which is the thing they exist to make cheap.
///
/// Not `DisclosureGroup`: that supplies a triangle and a title and no room for
/// anything else, and the markers section needs its "add" button in the header
/// beside the title. The whole header is also the hit target here, which a
/// `DisclosureGroup`'s is not.
struct AccordionSection<Content: View, Accessory: View>: View {
    let title: String
    /// Shown next to the title in the header — "5 markers", "128 words". It
    /// lives in the HEADER rather than inside the content on purpose: it is
    /// the one fact worth having while the section is CLOSED.
    let subtitle: String?
    @Binding var isExpanded: Bool
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider()
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                // Rotated rather than swapped for a second symbol, so the
                // triangle TURNS between the two states instead of cutting.
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // The whole bar, not just the triangle — a 10pt chevron is a target
        // you have to aim at, the same reason `ResizableDivider` is 8pt wide
        // around a hairline.
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isExpanded ? [.isSelected] : [])
    }
}

extension AccordionSection where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, isExpanded: Binding<Bool>,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, isExpanded: isExpanded,
                  accessory: { EmptyView() }, content: content)
    }
}
