import Testing
import Foundation
import AppKit
@testable import SnittExport

@Test("A file URL becomes a pasteboard item")
func fileBecomesPasteboardItem() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).mp4")
    try Data("not a real movie".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let items = ClipboardDestination.pasteboardItems(for: url)
    #expect(items.count == 1)
}

@Test("Copying writes a file URL a paste target can read back")
func copyWritesReadableURL() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).mp4")
    try Data("not a real movie".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    // A uniquely-named pasteboard, so the test never disturbs the user's own.
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    let ok = ClipboardDestination.copy(fileURL: url, to: pasteboard)

    #expect(ok)
    let read = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
    #expect(read?.first?.lastPathComponent == url.lastPathComponent)
}

@Test("Copying a file that does not exist fails rather than clearing the clipboard")
func missingFileDoesNotClobberClipboard() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).mp4")
    let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
    pasteboard.clearContents()
    pasteboard.setString("something the user copied earlier", forType: .string)

    let ok = ClipboardDestination.copy(fileURL: missing, to: pasteboard)

    #expect(ok == false)
    #expect(pasteboard.string(forType: .string) == "something the user copied earlier",
            "a failed copy must not destroy what the user already had")
}
