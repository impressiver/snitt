import Testing
@testable import SnittCapture

private func candidate(_ id: UInt32, _ bundle: String?, _ title: String?) -> WindowCandidate {
    WindowCandidate(windowID: id, bundleIdentifier: bundle,
                    title: title, width: 800, height: 600)
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
