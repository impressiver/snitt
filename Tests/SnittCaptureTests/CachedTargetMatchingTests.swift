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

@Test("Ignores window ids entirely when matching")
func ignoresWindowIDs() {
    // The same app, different window ids than any previous session — matching
    // must not depend on them, because they change every relaunch.
    let ref = TargetReference.window(bundleIdentifier: "com.apple.Safari",
                                     titleHint: "Docs")
    let found = CachedTargetResolver.bestMatch(for: ref, among: [
        candidate(99_001, "com.apple.Safari", "Docs"),
    ])
    #expect(found?.windowID == 99_001)
}
