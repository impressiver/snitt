import Testing
import Foundation

@Test("The access guard still polices Input Monitoring")
func guardCoversInputMonitoring() throws {
    // InputMonitoringAccess's real protection is AccessConformanceTests, which
    // fails the build if a file preflights a service without also requesting
    // it. That guard iterates a hard-coded service list — remove "ListenEvent"
    // from it and the guard silently stops policing the permission this whole
    // milestone depends on, with nothing failing.
    let source = try String(
        contentsOf: repositoryRoot().appendingPathComponent(
            "Tests/SnittCaptureTests/AccessConformanceTests.swift"),
        encoding: .utf8)
    #expect(source.contains("\"ListenEvent\""))
}
