import Testing
import Foundation
@testable import SnittDocument

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("AuditRecordTests-\(UUID().uuidString).jsonl")
}

@Test("A session round-trips through the log")
func recordRoundTrips() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let record = AuditRecord(sessionID: "S1", target: "Safari", initiator: "agent",
                             startedAt: Date(timeIntervalSince1970: 1000))
    try AuditLog.append(record, to: url)

    let read = try AuditLog.read(from: url)
    #expect(read.count == 1)
    #expect(read[0].sessionID == "S1")
    #expect(read[0].target == "Safari")
    #expect(read[0].initiator == "agent")
}

@Test("Appending does not rewrite earlier records")
func appendIsIncremental() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    for i in 1...3 {
        try AuditLog.append(AuditRecord(sessionID: "S\(i)", target: "T", initiator: "agent",
                                        startedAt: Date(timeIntervalSince1970: Double(i))), to: url)
    }
    // Discriminating against an implementation that decodes the whole file,
    // appends in memory and rewrites: that also passes a round-trip test,
    // and loses everything if the process dies mid-write.
    let lines = try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 3)
    #expect(try AuditLog.read(from: url).map(\.sessionID) == ["S1", "S2", "S3"])
}

@Test("Appending preserves a line the reader cannot parse")
func appendPreservesUnparseableLines() throws {
    // THE property of an append-only log, and the one nothing else pinned.
    //
    // A first attempt asserted that appending leaves earlier BYTES
    // untouched. That does not discriminate: JSONEncoder is deterministic
    // and Codable emits keys in declaration order, so a
    // decode-and-rewrite implementation reproduces byte-identical output.
    // Verified by mutation before this version was written.
    //
    // What genuinely differs is data loss. `read` SKIPS a line it cannot
    // decode, so a rewrite drops that line permanently, while a true
    // append leaves it alone. That is exactly the loss JSONL was chosen to
    // prevent, and it is observable.
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }

    try AuditLog.append(AuditRecord(sessionID: "S1", target: "T", initiator: "agent",
                                    startedAt: Date(timeIntervalSince1970: 1)), to: url)
    // A line from a future schema, or a half-written one from a crash:
    // unreadable now, but not ours to destroy.
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"unknownSchema\":true}\n".utf8))
    try handle.close()

    try AuditLog.append(AuditRecord(sessionID: "S2", target: "T", initiator: "agent",
                                    startedAt: Date(timeIntervalSince1970: 2)), to: url)

    let raw = try String(contentsOf: url, encoding: .utf8)
    #expect(raw.contains("unknownSchema"),
            "appending must not discard a line the reader could not parse")
    // And the records we CAN read are still both there.
    #expect(try AuditLog.read(from: url).map(\.sessionID) == ["S1", "S2"])
}

@Test("A truncated final line costs one record, not the log")
func truncatedLineLosesOnlyItself() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try AuditLog.append(AuditRecord(sessionID: "S1", target: "T", initiator: "agent",
                                    startedAt: Date()), to: url)
    // Simulate a crash mid-append.
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"sessionID":"S2","tar"#.utf8))
    try handle.close()

    // The whole point of JSONL: the audit matters most exactly when the
    // process died, so one bad line must not take the file with it.
    let read = try AuditLog.read(from: url)
    #expect(read.count == 1)
    #expect(read[0].sessionID == "S1")
}

@Test("No log yet is not an error, but an unreadable one is")
func absentAndUnreadableDiffer() throws {
    let missing = tempURL()
    // A machine that has never run an agent session has no log. That is
    // normal and must not fail an export.
    #expect(try AuditLog.read(from: missing).isEmpty)

    let unreadable = tempURL()
    defer { try? FileManager.default.removeItem(at: unreadable) }
    try Data([0xFF, 0xFE, 0xFD]).write(to: unreadable)
    // Invalid UTF-8 is a real fault. Returning [] here would report "no
    // agent sessions" for a machine that has run hundreds — the confidently
    // wrong answer §8 exists to prevent, in a new place.
    #expect(throws: (any Error).self) { _ = try AuditLog.read(from: unreadable) }
}

@Test("Duration comes from the two timestamps, and is nil while running")
func durationDerivesFromTimestamps() {
    var record = AuditRecord(sessionID: "S1", target: "T", initiator: "agent",
                             startedAt: Date(timeIntervalSince1970: 100))
    // A session still running has no duration. Reporting 0 would read as
    // "finished instantly" in an incident review.
    #expect(record.durationSeconds == nil)
    record.endedAt = Date(timeIntervalSince1970: 142)
    #expect(record.durationSeconds == 42)
}

@Test("Only the most recent N are returned, newest last")
func recentReturnsTheTail() throws {
    let url = tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    for i in 1...5 {
        try AuditLog.append(AuditRecord(sessionID: "S\(i)", target: "T", initiator: "agent",
                                        startedAt: Date(timeIntervalSince1970: Double(i))), to: url)
    }
    // A diagnostics bundle wants the recent tail, not a year of history.
    // Discriminating against an implementation returning the first N.
    #expect(try AuditLog.recent(2, from: url).map(\.sessionID) == ["S4", "S5"])
}
