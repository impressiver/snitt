import Foundation
import AppKit

/// Puts a finished recording on the clipboard.
///
/// Copying is the default outcome of stopping a recording, not a step the user
/// takes afterwards (§4.1). The gap between "the file exists" and "it is pasted
/// into Slack" is where the time-to-share budget is actually spent.
public enum ClipboardDestination {
    public static func pasteboardItems(for fileURL: URL) -> [NSPasteboardWriting] {
        [fileURL as NSURL]
    }

    /// Copies the file, returning false if it could not be copied.
    ///
    /// A missing file is refused BEFORE the pasteboard is cleared, so a failed
    /// copy never destroys whatever the user already had on their clipboard.
    @discardableResult
    public static func copy(fileURL: URL, to pasteboard: NSPasteboard) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects(pasteboardItems(for: fileURL))
    }
}
