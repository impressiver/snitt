import Testing
import Foundation
@testable import SnittAutomation

@Test("A whole message in one chunk yields exactly one payload")
func singleWholeMessage() {
    var framer = LineFramer()
    let out = framer.append(LineFramer.frame(Data("hello".utf8)))
    #expect(out.count == 1)
    #expect(String(data: out[0], encoding: .utf8) == "hello")
}

@Test("A message split across chunks is reassembled, not dropped")
func splitMessageIsReassembled() {
    var framer = LineFramer()
    let whole = LineFramer.frame(Data("abcdef".utf8))
    let first = whole.prefix(3), second = whole.suffix(from: 3)

    #expect(framer.append(Data(first)).isEmpty, "a partial message must yield nothing yet")
    let out = framer.append(Data(second))
    #expect(out.count == 1)
    #expect(String(data: out[0], encoding: .utf8) == "abcdef")
}

@Test("Several messages coalesced into one chunk all come out, in order")
func coalescedMessagesAllEmerge() {
    var framer = LineFramer()
    var chunk = Data()
    for word in ["one", "two", "three"] { chunk.append(LineFramer.frame(Data(word.utf8))) }

    let out = framer.append(chunk)
    #expect(out.count == 3, "a single read can carry more than one message")
    #expect(out.map { String(data: $0, encoding: .utf8) } == ["one", "two", "three"])
}

@Test("An empty line is skipped rather than surfacing as an empty message")
func emptyLinesAreSkipped() {
    var framer = LineFramer()
    let out = framer.append(Data("\n\nvalue\n".utf8))
    #expect(out.count == 1)
    #expect(String(data: out[0], encoding: .utf8) == "value")
}
