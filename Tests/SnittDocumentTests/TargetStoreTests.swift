import Testing
import Foundation
@testable import SnittDocument

private func tempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("json")
}

@Test("An empty store loads nil rather than throwing")
func emptyStoreLoadsNil() {
    let store = TargetStore(fileURL: tempStoreURL())
    #expect(store.load() == nil)
}

@Test("A saved reference survives a reload")
func savedReferenceReloads() throws {
    let url = tempStoreURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = TargetStore(fileURL: url)
    try store.save(StoredTargetReference(kind: "window",
                                         bundleIdentifier: "com.apple.Safari",
                                         titleHint: "Docs",
                                         displayID: nil))

    let reloaded = TargetStore(fileURL: url).load()
    #expect(reloaded?.bundleIdentifier == "com.apple.Safari")
    #expect(reloaded?.kind == "window")
}

@Test("A corrupt store loads nil instead of throwing or crashing")
func corruptStoreLoadsNil() throws {
    let url = tempStoreURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("this is not json".utf8).write(to: url)

    let store = TargetStore(fileURL: url)
    #expect(store.load() == nil, "a corrupt cache must degrade to 'no cached target', never crash")
}

@Test("Clearing removes the stored reference")
func clearRemovesReference() throws {
    let url = tempStoreURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = TargetStore(fileURL: url)
    try store.save(StoredTargetReference(kind: "display",
                                         bundleIdentifier: nil,
                                         titleHint: nil,
                                         displayID: 3))
    try store.clear()
    #expect(store.load() == nil)
}
