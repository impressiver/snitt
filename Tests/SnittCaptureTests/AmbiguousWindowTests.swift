// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittCapture

/// Choosing which window an agent meant.
///
/// Written against a real incident: an agent asked to record Chrome with ten
/// windows open, and the resolver returned the LARGEST — silently recording a
/// private pull request instead of the intended demo. Nobody found out until
/// the recording was watched.
///
/// The rule that fixes it is not "pick better", it is "refuse to pick".
@Suite
struct AmbiguousWindowTests {
    private func window(_ id: UInt32, _ title: String,
                        width: Int = 1200, height: Int = 800) -> WindowCandidate {
        WindowCandidate(windowID: id, bundleIdentifier: "com.google.Chrome",
                        applicationName: "Chrome", title: title,
                        width: width, height: height, processID: 42)
    }

    private var tenWindows: [WindowCandidate] {
        (1...10).map { window(UInt32($0), "Tab \($0)",
                              width: 800 + $0 * 10, height: 600) }
    }

    @Test("Several windows and no way to choose is AMBIGUOUS, not a guess")
    func severalWindowsIsAmbiguous() {
        let reference = TargetReference.window(bundleIdentifier: "com.google.Chrome",
                                               titleHint: nil)
        guard case .ambiguous(let candidates) =
                CachedTargetResolver.match(for: reference, among: tenWindows) else {
            Issue.record("ten windows resolved to a single answer — the incident"); return
        }
        #expect(candidates.count == 10)
    }

    @Test("A windowID names exactly one window")
    func windowIDSelectsExactly() {
        let reference = TargetReference.window(bundleIdentifier: "com.google.Chrome",
                                               titleHint: nil, windowID: 7)
        guard case .one(let candidate) =
                CachedTargetResolver.match(for: reference, among: tenWindows) else {
            Issue.record("windowID did not resolve"); return
        }
        // NOT the largest — window 10 is. That is the whole point.
        #expect(candidate.windowID == 7)
        #expect(candidate.title == "Tab 7")
    }

    @Test("A windowID naming no open window fails rather than falling back")
    func unknownWindowIDDoesNotFallBack() {
        // Falling back to "some window of that app" would reintroduce the
        // defect for the exact caller trying hardest to avoid it.
        let reference = TargetReference.window(bundleIdentifier: "com.google.Chrome",
                                               titleHint: nil, windowID: 999)
        #expect(CachedTargetResolver.match(for: reference, among: tenWindows) == .none)
    }

    @Test("A title still disambiguates when it matches")
    func titleHintStillWorks() {
        let reference = TargetReference.window(bundleIdentifier: "com.google.Chrome",
                                               titleHint: "Tab 3")
        guard case .one(let candidate) =
                CachedTargetResolver.match(for: reference, among: tenWindows) else {
            Issue.record("titleHint did not resolve"); return
        }
        #expect(candidate.windowID == 3)
    }

    @Test("One window needs no disambiguation")
    func singleWindowIsUnambiguous() {
        let reference = TargetReference.window(bundleIdentifier: "com.google.Chrome",
                                               titleHint: nil)
        guard case .one = CachedTargetResolver.match(for: reference,
                                                     among: [window(1, "only")]) else {
            Issue.record("a single window was reported ambiguous"); return
        }
    }

    @Test("Windows below the size floor do not create ambiguity")
    func palettesDoNotCountAsCandidates() {
        // One real window plus two palettes must resolve, not refuse — the
        // floor exists precisely so an inspector is not a candidate.
        let reference = TargetReference.window(bundleIdentifier: "com.google.Chrome",
                                               titleHint: nil)
        let candidates = [window(1, "real"),
                          window(2, "palette", width: 60, height: 200),
                          window(3, "tooltip", width: 80, height: 40)]
        guard case .one(let candidate) =
                CachedTargetResolver.match(for: reference, among: candidates) else {
            Issue.record("palettes made a single real window ambiguous"); return
        }
        #expect(candidate.windowID == 1)
    }

    @Test("The hotkey path still prefers the largest rather than refusing")
    func bestMatchStillPicksLargest() {
        // `bestMatch` serves a person pressing a key with a remembered target,
        // where recording the right app beats recording nothing. Only the AGENT
        // path refuses, because nobody is watching it.
        let reference = TargetReference.window(bundleIdentifier: "com.google.Chrome",
                                               titleHint: nil)
        #expect(CachedTargetResolver.bestMatch(for: reference, among: tenWindows)?.windowID == 10)
    }
}
