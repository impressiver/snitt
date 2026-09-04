import Testing
import Foundation

@Test("The access guard still polices Input Monitoring")
func guardCoversInputMonitoring() throws {
    // InputMonitoringAccess's real protection is AccessConformanceTests, which
    // fails the build if a file preflights a service without also requesting
    // it. That guard iterates a service list — drop "ListenEvent" from it and
    // the guard silently stops policing the permission this whole milestone
    // depends on, with nothing failing.
    //
    // This is deliberately BEHAVIOURAL. The earlier version read
    // AccessConformanceTests.swift as raw source and asserted the literal
    // "ListenEvent" appeared somewhere in it — which a doc comment satisfies,
    // the exact false negative `strippingCommentsAndLiterals` was written to
    // close. Running the scanner against fixtures cannot be satisfied by a
    // mention, and survives the file being renamed or reorganised.
    let offending = """
    import CoreGraphics
    enum Broken {
        static func isGranted() -> Bool { CGPreflightListenEventAccess() }
    }
    """
    #expect(preflightOffenders(in: offending, fileName: "Broken.swift").count == 1,
            "a file that only preflights ListenEvent must be flagged")

    let correct = """
    import CoreGraphics
    enum Fine {
        static func isGranted() -> Bool { CGPreflightListenEventAccess() }
        static func ensureGranted() -> Bool {
            if CGPreflightListenEventAccess() { return true }
            return CGRequestListenEventAccess()
        }
    }
    """
    #expect(preflightOffenders(in: correct, fileName: "Fine.swift").isEmpty,
            "a file that preflights AND requests ListenEvent must not be flagged")

    // And the mention-only case the raw-text version could not tell apart.
    let mentionOnly = """
    /// Talks about CGPreflightListenEventAccess without calling it.
    enum Doc {}
    """
    #expect(preflightOffenders(in: mentionOnly, fileName: "Doc.swift").isEmpty,
            "a doc comment naming the API is not a call site")
}
