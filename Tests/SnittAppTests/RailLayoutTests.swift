// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittApp

/// How the side panel divides itself between Markers and Transcript.
///
/// The panel is SwiftUI, which renders blank on this project's headless
/// runner — so the appearance cannot be asserted and the DECISIONS can. All
/// four combinations of the two sections are covered, because three of them
/// are reachable by one click from the fourth and the interesting rules live
/// in the transitions.
struct RailLayoutTests {

    @Test("Both open: the transcript keeps its dragged height, the markers list takes the rest")
    func bothOpenSharesTheRail() {
        #expect(RailLayout.transcriptHeight(markersExpanded: true, transcriptExpanded: true,
                                            stored: 300) == .fixed(300))
        // Exactly ONE of the two may own a number. If both did they would
        // disagree about the rail's height and the loser would be clipped.
        #expect(RailLayout.markersHeight(markersExpanded: true) == .fill)
    }

    @Test("Transcript alone takes the whole rail, stored height and all")
    func aloneItFills() {
        // A section alone in the rail that kept its fixed height would leave a
        // band of empty panel beneath it — which reads as the list having
        // ended, not as the window being taller than the list.
        #expect(RailLayout.transcriptHeight(markersExpanded: false, transcriptExpanded: true,
                                            stored: 300) == .fill)
        #expect(RailLayout.markersHeight(markersExpanded: false) == .collapsed)
    }

    @Test("A closed section is its header and nothing more")
    func closedIsCollapsed() {
        #expect(RailLayout.transcriptHeight(markersExpanded: true, transcriptExpanded: false,
                                            stored: 300) == .collapsed)
        // And the stored height is IGNORED rather than applied to a closed
        // section, which would leave 300pt of nothing under the header.
        #expect(RailLayout.transcriptHeight(markersExpanded: false, transcriptExpanded: false,
                                            stored: 300) == .collapsed)
    }

    @Test("The drag handle appears only when there are two open sections to divide")
    func dividerNeedsBothSections() {
        // A handle between an open section and a closed header resizes
        // nothing: a control that responds to dragging and changes no pixels
        // is worse than an absent one.
        #expect(RailLayout.showsDivider(markersExpanded: true, transcriptExpanded: true))
        #expect(!RailLayout.showsDivider(markersExpanded: true, transcriptExpanded: false))
        #expect(!RailLayout.showsDivider(markersExpanded: false, transcriptExpanded: true))
        #expect(!RailLayout.showsDivider(markersExpanded: false, transcriptExpanded: false))
    }

    @Test("Both sections can be open at once")
    func theAccordionIsNotEitherOr() {
        // The requirement, stated as a test rather than left to the view: these
        // are two indexes of one recording and they are read TOGETHER — a
        // marker says where something happened and the transcript says what
        // was said there. An either/or accordion would make comparing them a
        // pair of clicks, which is the thing they exist to make cheap. Nothing
        // in `RailLayout` may ever answer `.collapsed` for one BECAUSE the
        // other is open.
        #expect(RailLayout.markersHeight(markersExpanded: true) != .collapsed)
        #expect(RailLayout.transcriptHeight(markersExpanded: true, transcriptExpanded: true,
                                            stored: 300) != .collapsed)
    }

    @Test("Only a fixed height reaches SwiftUI as a number")
    func maxHeightMapping() {
        // `nil` is how a SwiftUI frame says "size to your content", which is
        // what a closed section needs and what `.fill` must NOT be turned into
        // — a filling section that became nil would shrink to its header and
        // look closed while its disclosure triangle pointed down.
        #expect(RailLayout.Height.collapsed.maxHeight(fillIsInfinite: true) == nil)
        #expect(RailLayout.Height.fill.maxHeight(fillIsInfinite: true) == .infinity)
        #expect(RailLayout.Height.fixed(240).maxHeight(fillIsInfinite: true) == 240)
    }
}
