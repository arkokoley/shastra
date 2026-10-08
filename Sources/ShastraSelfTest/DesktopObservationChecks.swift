import Foundation
import ShastraCore

/// Read-only live observation check. This does not certify automatic desktop control or caller enrollment.
func verifyCursorObservation(nativeID: String) async throws {
    guard UUID(uuidString: nativeID) != nil else { throw ShastraError.invalidResponse("Expected a native Cursor UUID") }
    let locator = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
    let source = DiscoveredSession(id: "cursor-editor:\(nativeID)", provider: .cursor, kind: "Cursor Editor",
        vendorID: nativeID, title: "Desktop observation probe", workingDirectory: "/Users/arkokoley/code/Test",
        locator: locator, updatedAt: .now)
    let entries = try await ConversationCatalog.load(source)
    guard entries.count == 4, entries.map(\.kind) == [.user, .assistant, .user, .assistant],
          entries[0].text.contains("P0-20260930-A"), entries[1].text == "SHASTRA-P0-A-ACK",
          entries[2].text.contains("P0-20260930-B"), entries[3].text.contains("SHASTRA-P0-B-ACK") else {
        throw ShastraError.invalidResponse("Disposable probe does not contain the expected four native messages")
    }
    let root = FileManager.default.temporaryDirectory.appending(path: "shastra-observe-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try ContinuityDatabase(directory: root)
    var c = source.placeholder()
    guard let endpoint = c.sourceEndpoint else { throw ShastraError.invalidResponse("Missing source endpoint") }
    c.entries = HistoryReconciler.merge(entries, endpoint: endpoint, into: [])
    try db.save([c])
    let second = try await ConversationCatalog.load(source)
    c.entries = HistoryReconciler.merge(second, endpoint: endpoint, into: c.entries)
    try db.save([c])
    let restored = try ContinuityDatabase(directory: root).load()
    precondition(restored.first?.entries.count == 4)
    precondition(restored.first?.entries.map(\.id) == c.entries.map(\.id))
    print("PASS: observed 4 ordered native Cursor messages, deduplicated refresh, and preserved identity across SQLite reopen")
    print("Not certified: Shastra desktop send driver, caller enrollment, account isolation, app tools, exact-thread navigation")
}
