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
///
/// If the buffer ever exceeds `maximumMessageBytes` without hitting a terminator,
/// the framer is poisoned: all further appends throw `messageTooLarge` and the
/// connection is expected to close. Silent discard would corrupt the stream by
/// emitting fragments of a discarded message as if they were complete messages
/// sent by the client.
public struct LineFramer: Sendable {
    /// Refuse absurd input rather than buffering without bound.
    public static let maximumMessageBytes = 1 << 20

    private var buffer = Data()

    /// Once the buffer has overflowed, the stream is no longer known to sit on a
    /// message boundary — the bytes that follow are the tail of a message whose
    /// head was discarded. Resuming would mean emitting a fragment as if it were
    /// a whole message, so the framer refuses everything from here on and the
    /// connection is expected to be closed.
    private var poisoned = false

    public init() {}

    public static func frame(_ payload: Data) -> Data {
        var out = payload
        out.append(0x0A)
        return out
    }

    /// Appends a chunk and returns every complete message it completed.
    /// Throws `FramingError.messageTooLarge` if the buffer ever exceeds `maximumMessageBytes`.
    /// Once an overflow is detected, the framer is poisoned and all further appends throw.
    public mutating func append(_ data: Data) throws -> [Data] {
        if poisoned {
            throw FramingError.messageTooLarge(buffer.count)
        }

        buffer.append(data)
        var messages: [Data] = []

        while let index = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<index]
            buffer = Data(buffer[buffer.index(after: index)...])
            if !line.isEmpty { messages.append(Data(line)) }
        }

        if buffer.count > Self.maximumMessageBytes {
            poisoned = true
            throw FramingError.messageTooLarge(buffer.count)
        }

        return messages
    }
}
