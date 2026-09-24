// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import Testing
@testable import SnittCapture

private func candidate(_ id: UInt32, _ bundle: String?, _ title: String?,
                       pid: pid_t? = 4242) -> WindowCandidate {
    WindowCandidate(windowID: id, bundleIdentifier: bundle,
                    applicationName: "App", title: title,
                    width: 800, height: 600, processID: pid)
}

@Test("Matches the only window of the referenced application")
func matchesSoleWindow() {
    let ref = TargetReference.window(bundleIdentifier: "com.apple.Safari",
                                     titleHint: nil)
    let found = CachedTargetResolver.bestMatch(for: ref, among: [
        candidate(1, "com.apple.Xcode", "Project"),
        candidate(2, "com.apple.Safari", "Anything"),
    ])
    #expect(found?.windowID == 2)
}

@Test("Prefers the window whose title matches the hint")
func prefersTitleHint() {
    let ref = TargetReference.window(bundleIdentifier: "com.apple.Safari",
                                     titleHint: "Release Notes")
    let found = CachedTargetResolver.bestMatch(for: ref, among: [
        candidate(1, "com.apple.Safari", "Inbox"),
        candidate(2, "com.apple.Safari", "Release Notes"),
        candidate(3, "com.apple.Safari", "Docs"),
    ])
    #expect(found?.windowID == 2)
}

@Test("Falls back to the first window of the app when no title matches")
func fallsBackWhenHintMisses() {
    let ref = TargetReference.window(bundleIdentifier: "com.apple.Safari",
                                     titleHint: "Long Gone")
    let found = CachedTargetResolver.bestMatch(for: ref, among: [
        candidate(7, "com.apple.Safari", "Inbox"),
        candidate(8, "com.apple.Safari", "Docs"),
    ])
    #expect(found?.windowID == 7,
            "a stale title must not prevent recording the right app")
}

@Test("Returns nil when the application has no windows")
func noMatchWhenAppAbsent() {
    let ref = TargetReference.window(bundleIdentifier: "com.apple.Safari",
                                     titleHint: nil)
    let found = CachedTargetResolver.bestMatch(for: ref, among: [
        candidate(1, "com.apple.Xcode", "Project"),
    ])
    #expect(found == nil)
}

@Test("Matching ignores window ids — an id-ordered match would pick the wrong window")
func ignoresWindowIDs() {
    let ref = TargetReference.window(bundleIdentifier: "com.apple.Safari",
                                     titleHint: "Docs")
    // Two windows of the same app. The one matching the title hint deliberately
    // has the HIGHER id and comes SECOND, so an implementation that preferred
    // the lowest id, or simply took the first window without consulting the
    // title, returns the wrong one and fails this test.
    let found = CachedTargetResolver.bestMatch(for: ref, among: [
        candidate(1, "com.apple.Safari", "Inbox"),
        candidate(99_001, "com.apple.Safari", "Docs"),
    ])
    #expect(found?.windowID == 99_001,
            "the title hint must decide, not window id order or list position")
}

private func sized(_ id: UInt32, _ bundle: String?, _ title: String?,
                   _ width: Int, _ height: Int) -> WindowCandidate {
    WindowCandidate(windowID: id, bundleIdentifier: bundle,
                    applicationName: "App", title: title,
                    width: width, height: height, processID: 4242)
}

@Test("With no title hint, the LARGEST window of the app wins")
func prefersLargestWindow() {
    // The agent path always passes titleHint: nil, because `--app <bundle-id>`
    // has no title to give. `sameApp.first` therefore meant "an arbitrary
    // window": ScreenCaptureKit's ordering is not a ranking. The main window is
    // deliberately LAST here, so the old implementation returns the palette.
    let ref = TargetReference.window(bundleIdentifier: "com.example.Editor",
                                     titleHint: nil)
    let found = CachedTargetResolver.bestMatch(for: ref, among: [
        sized(1, "com.example.Editor", "Inspector", 240, 700),
        sized(2, "com.example.Editor", "Palette", 300, 400),
        sized(3, "com.example.Editor", "Untitled.txt", 1400, 900),
    ])
    #expect(found?.windowID == 3,
            "an agent asking for an app must get its main window, not a side panel")
}

@Test("Windows below the size floor are not recordable at all")
func rejectsTinyWindows() {
    let ref = TargetReference.window(bundleIdentifier: "com.example.Editor",
                                     titleHint: nil)
    let found = CachedTargetResolver.bestMatch(for: ref, among: [
        sized(1, "com.example.Editor", "Toolbar", 60, 800),
        sized(2, "com.example.Editor", "Tooltip", 400, 24),
    ])
    #expect(found == nil,
            "target_not_found is a fact an agent can act on; a 60-pixel strip is not")
}

@Test("The size floor applies to a title-hint match too")
func titleHintCannotSelectATinyWindow() {
    let ref = TargetReference.window(bundleIdentifier: "com.example.Editor",
                                     titleHint: "Palette")
    let found = CachedTargetResolver.bestMatch(for: ref, among: [
        sized(1, "com.example.Editor", "Palette", 80, 80),
        sized(2, "com.example.Editor", "Untitled.txt", 1400, 900),
    ])
    #expect(found?.windowID == 2,
            "a stale hint naming an unusable window must fall through, not win")
}

@Test("Equal-area windows keep list order rather than depending on tie-breaking")
func equalAreasAreStable() {
    let ref = TargetReference.window(bundleIdentifier: "com.example.Editor",
                                     titleHint: nil)
    let found = CachedTargetResolver.bestMatch(for: ref, among: [
        sized(7, "com.example.Editor", "One", 800, 600),
        sized(8, "com.example.Editor", "Two", 600, 800),
    ])
    #expect(found?.windowID == 7,
            "identical areas must not make the choice depend on how max(by:) breaks ties")
}

@Test("An app with only tiny windows is reported as too small, not as gone")
func tooSmallIsNotTheSameAsGone() {
    // `bestMatch` returns nil for both, and folding them together told an agent
    // that its RUNNING application "may not be running" — so it retried or gave
    // up instead of resizing the window or recording a display.
    let ref = TargetReference.window(bundleIdentifier: "com.example.Editor",
                                     titleHint: nil)
    let onlyTiny = CachedTargetResolver.failure(for: ref, among: [
        sized(1, "com.example.Editor", "Toolbar", 60, 800),
    ])
    #expect(onlyTiny == .targetTooSmall("com.example.Editor"))

    let absent = CachedTargetResolver.failure(for: ref, among: [
        sized(1, "com.example.Other", "Window", 900, 700),
    ])
    #expect(absent == .targetGone("com.example.Editor"))
}

@Test("A reference with no bundle identifier is gone, not too small")
func noBundleIdentifierIsGone() {
    // Guards against `$0.bundleIdentifier == nil` matching every window that
    // happens to carry no owning application.
    let ref = TargetReference.display(id: 3)
    #expect(CachedTargetResolver.failure(for: ref, among: [
        sized(1, nil, "Unowned", 900, 700),
    ]) == .targetGone("unknown application"))
}

@Test("A resolved window descriptor carries the pid auto-focus needs")
func resolvedWindowDescriptorCarriesProcessID() {
    // The discriminating check for the dead auto-focus. `processID` was added to
    // `CaptureTargetDescriptor` and wired at exactly one site —
    // `CaptureTarget.descriptor`, which only ever serves `listTargets()` — so
    // every descriptor that reached `RecordingCoordinator.startRecording` had a
    // nil pid, `WindowFocuser.focus(descriptor:)` returned false at its first
    // guard, and the coordinator discarded that with `_ =`. Auto-focus (§4.13)
    // never fired, while `WindowFocuserTests` passed against hand-built
    // descriptors that carried a pid.
    //
    // This asserts the seam that IS reachable without a live display: the
    // descriptor `CachedTargetResolver.resolve()` returns is built by this
    // function, from the matched candidate. The one hop it cannot cover is the
    // SCWindow → WindowCandidate map inside `resolve()`, which needs real
    // screen enumeration; the pid is read there on the same line as the bundle
    // identifier the matching already depends on.
    let match = candidate(7, "com.example.App", "Main")
    let descriptor = CachedTargetResolver.descriptor(for: match,
                                                     pixelSize: (width: 1920, height: 1080))
    #expect(descriptor.processID == 4242,
            "without a pid the focuser cannot activate anything and §4.13 is dead code")
    // Both halves of what the focuser checks, so this cannot pass against a
    // descriptor that carries a pid but is not a window target.
    #expect(descriptor.kind == CaptureTargetDescriptor.Kind.window.rawValue)
    #expect(descriptor.title == "Main")
    #expect(descriptor.applicationName == "App")
}

@Test("A window id that matches nothing says so, rather than blaming the app")
func anUnknownWindowIDIsItsOwnFailure() {
    // MEASURED IN A REAL SESSION. A caller asked for a window id that did not
    // exist, against a Chrome with thirteen windows open and recording happily:
    //
    //   com.google.Chrome has no window larger than 100×100 to record.
    //   ... Resize the window, or record a display ...
    //
    // Both halves false, and the remedy fixes nothing. `failure` asked only
    // "does this app have any window on screen?", so a named id that matched
    // nothing fell into `targetTooSmall` whenever the app was running.
    //
    // Verified to fail by removing the windowID branch: reports
    // `.targetTooSmall`, exactly as reported.
    let ref = TargetReference.window(bundleIdentifier: "com.example.Editor",
                                     titleHint: nil, windowID: 999_999)
    let result = CachedTargetResolver.failure(for: ref, among: [
        sized(7, "com.example.Editor", "One", 1280, 800),
        sized(8, "com.example.Editor", "Two", 1280, 800),
    ])
    #expect(result == .windowNotFound(id: 999_999, app: "com.example.Editor"),
            "got \(result)")
}

@Test("The id is checked before anything is said about the application")
func theIDOutranksTheApplication() {
    // Order is the fix, not just the new case. A caller who named an id is
    // asking about THAT window; anything said about the application as a whole
    // answers a question they did not ask. With only tiny windows present, the
    // app-level answer would be `targetTooSmall` and would still be beside the
    // point — the id they gave is not among them either.
    let ref = TargetReference.window(bundleIdentifier: "com.example.Editor",
                                     titleHint: nil, windowID: 4242)
    #expect(CachedTargetResolver.failure(for: ref, among: [
        sized(1, "com.example.Editor", "Toolbar", 60, 800),
    ]) == .windowNotFound(id: 4242, app: "com.example.Editor"))
}

@Test("A window id that DOES match leaves the other diagnoses alone")
func aMatchingIDDoesNotShadowTheOtherReasons() {
    // THE CONTROL. Checking the id first must not swallow the cases that were
    // already right: an id present among candidates that are all too small is
    // still a too-small problem, and that is the diagnosis with the useful
    // remedy.
    let ref = TargetReference.window(bundleIdentifier: "com.example.Editor",
                                     titleHint: nil, windowID: 1)
    #expect(CachedTargetResolver.failure(for: ref, among: [
        sized(1, "com.example.Editor", "Toolbar", 60, 800),
    ]) == .targetTooSmall("com.example.Editor"))
}
