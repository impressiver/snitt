import Foundation

public enum FramingError: Error, Equatable {
    case messageTooLarge(Int)
}

/// Splits a byte stream into newline-delimited messages.
///
/// A stream socket delivers arbitrary chunks: one read can hold half a message or
/// three whole ones. This buffers partial input and emits only complete messages,
/// which is why it is a separate, directly tested type — framing bugs otherwise
/// appear only under load.
///
/// The payload is JSON, which never contains a raw newline outside a string
/// literal, and `JSONEncoder` does not emit newlines inside strings unescaped —
/// so a bare `\n` is an unambiguous terminator.
public struct LineFramer: Sendable {
    /// Refuse absurd input rather than buffering without bound.
    public static let maximumMessageBytes = 1 << 20

    private var buffer = Data()

    public init() {}

    public static func frame(_ payload: Data) -> Data {
        var out = payload
        out.append(0x0A)
        return out
    }

    /// Appends a chunk and returns every complete message it completed.
    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var messages: [Data] = []

        while let index = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<index]
            buffer = Data(buffer[buffer.index(after: index)...])
            if !line.isEmpty { messages.append(Data(line)) }
        }

        if buffer.count > Self.maximumMessageBytes { buffer.removeAll() }
        return messages
    }
}
