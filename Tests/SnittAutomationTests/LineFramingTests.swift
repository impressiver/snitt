// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
import Foundation
@testable import SnittAutomation

@Test("A whole message in one chunk yields exactly one payload")
func singleWholeMessage() throws {
    var framer = LineFramer()
    let out = try framer.append(LineFramer.frame(Data("hello".utf8)))
    #expect(out.count == 1)
    #expect(String(data: out[0], encoding: .utf8) == "hello")
}

@Test("A message split across chunks is reassembled, not dropped")
func splitMessageIsReassembled() throws {
    var framer = LineFramer()
    let whole = LineFramer.frame(Data("abcdef".utf8))
    let first = whole.prefix(3), second = whole.suffix(from: 3)

    #expect(try framer.append(Data(first)).isEmpty, "a partial message must yield nothing yet")
    let out = try framer.append(Data(second))
    #expect(out.count == 1)
    #expect(String(data: out[0], encoding: .utf8) == "abcdef")
}

@Test("Several messages coalesced into one chunk all come out, in order")
func coalescedMessagesAllEmerge() throws {
    var framer = LineFramer()
    var chunk = Data()
    for word in ["one", "two", "three"] { chunk.append(LineFramer.frame(Data(word.utf8))) }

    let out = try framer.append(chunk)
    #expect(out.count == 3, "a single read can carry more than one message")
    #expect(out.map { String(data: $0, encoding: .utf8) } == ["one", "two", "three"])
}

@Test("An empty line is skipped rather than surfacing as an empty message")
func emptyLinesAreSkipped() throws {
    var framer = LineFramer()
    let out = try framer.append(Data("\n\nvalue\n".utf8))
    #expect(out.count == 1)
    #expect(String(data: out[0], encoding: .utf8) == "value")
}

@Test("An oversized message throws rather than silently discarding")
func oversizeThrows() {
    var framer = LineFramer()
    let huge = Data(repeating: 0x41, count: LineFramer.maximumMessageBytes + 1)
    #expect(throws: FramingError.self) { _ = try framer.append(huge) }
}

@Test("After an overflow the framer refuses everything, rather than resuming mid-message")
func overflowPoisonsTheFramer() {
    // The bug this pins: after discarding an oversized message's head, the
    // tail that follows would otherwise be emitted as a legitimate short
    // message that no client ever sent.
    var framer = LineFramer()
    let huge = Data(repeating: 0x41, count: LineFramer.maximumMessageBytes + 1)
    #expect(throws: FramingError.self) { _ = try framer.append(huge) }
    #expect(throws: FramingError.self) {
        _ = try framer.append(Data("TAIL\nnext\n".utf8))
    }
}
