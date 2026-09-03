import Testing
@testable import SnittAutomation

private func policy(enabled: Bool = true,
                    fullDisplay: Bool = false,
                    maxSeconds: Double = 600) -> ConsentPolicy {
    ConsentPolicy(agentRecordingEnabled: enabled,
                  fullDisplayAllowed: fullDisplay,
                  maximumSessionSeconds: maxSeconds)
}

@Test("Agent recording disabled refuses every request with consent_required")
func disabledRefusesEverything() {
    let error = policy(enabled: false)
        .evaluate(StartOptions(bundleIdentifier: "com.apple.Safari"))
    #expect(error?.code == .consentRequired)
}

@Test("A window request is allowed when agent recording is enabled")
func windowRequestAllowed() {
    #expect(policy().evaluate(StartOptions(bundleIdentifier: "com.apple.Safari")) == nil)
}

@Test("A display request is refused unless full-display was granted specifically")
func displayRefusedByDefault() {
    // §5.3: an agent may not silently escalate to full-display. This is the
    // request a naive implementation would wave through, so it is tested directly.
    let error = policy(fullDisplay: false).evaluate(StartOptions(displayID: 1))
    #expect(error?.code == .consentRequired)
    #expect(error?.hint != nil, "a refusal an agent cannot act on is a dead end")
}

@Test("A display request is allowed once full-display is granted")
func displayAllowedWhenGranted() {
    #expect(policy(fullDisplay: true).evaluate(StartOptions(displayID: 1)) == nil)
}

@Test("A request naming neither a window nor a display is refused")
func targetlessRequestRefused() {
    #expect(policy().evaluate(StartOptions())?.code == .targetNotFound)
}

@Test("An over-long requested duration is capped, not honoured")
func durationIsCapped() {
    // §5.3: a hung agent must not be able to fill the disk, so the cap is a
    // ceiling rather than a default an agent can raise.
    #expect(policy(maxSeconds: 600).effectiveMaxDuration(99_999) == 600)
    #expect(policy(maxSeconds: 600).effectiveMaxDuration(30) == 30)
    #expect(policy(maxSeconds: 600).effectiveMaxDuration(nil) == 600)
}
