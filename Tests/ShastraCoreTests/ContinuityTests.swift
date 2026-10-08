import Foundation
import Testing
@testable import ShastraCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "shastra-continuity-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func fixture() -> Conversation {
    var c = Conversation(provider: .codex, workingDirectory: "/tmp/project")
    c.title = "Keep all constraints"
    c.vendorSessionID = "managed-after-import"
    c.sourceIdentity = "codex:original-native-id"
    c.sourceKind = "Codex"
    c.accountID = UUID()
    c.entries = [.init(kind: .user, text: "Never delete the fixtures"), .init(kind: .assistant, text: "Understood")]
    return c
}

@Test func migratesLegacyWithoutLosingIdentityOrFallingBack() throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let original = fixture()
    let json = root.appending(path: "conversations.json")
    try JSONEncoder().encode([original]).write(to: json)
    let db = try ContinuityDatabase(directory: root)
    var result = try #require(db.load().first)
    #expect(result.id == original.id)
    #expect(result.accountID == original.accountID)
    #expect(result.entries.map(\.id) == original.entries.map(\.id))
    #expect(result.entries.allSatisfy { $0.endpointID == nil })
    #expect(result.nativeEndpoints.count == 2)
    #expect(result.sourceEndpoint?.nativeThreadID == "original-native-id")
    #expect(result.activeEndpoint?.nativeThreadID == "managed-after-import")
    #expect(result.activeEndpoint?.ownership == .needsReconciliation)
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "MigrationBackup-v1/conversations.json").path))
    result.entries.append(.init(kind: .user, text: "A new durable turn"))
    try db.save([result])
    try Data("broken legacy file".utf8).write(to: json)
    let reopened = try ContinuityDatabase(directory: root)
    #expect(try reopened.load().first?.entries.count == 3)
    let export = root.appending(path: "export.json")
    try reopened.export(to: export)
    #expect(try JSONDecoder().decode([Conversation].self, from: Data(contentsOf: export)).first?.id == original.id)
}

@Test func corruptLegacyDoesNotCommitEmptyMigration() throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let json = root.appending(path: "conversations.json")
    try Data("bad".utf8).write(to: json)
    #expect(throws: (any Error).self) { try ContinuityDatabase(directory: root) }
    try JSONEncoder().encode([fixture()]).write(to: json)
    #expect(try ContinuityDatabase(directory: root).load().count == 1)
}

@Test func saveRollbackPreservesPreviousEntries() throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let db = try ContinuityDatabase(directory: root)
    var c = fixture(); try db.save([c])
    c.title = "Must be rolled back"
    var invalid = Entry(kind: .user, text: "invalid foreign endpoint")
    invalid.endpointID = UUID(); c.entries.append(invalid)
    #expect(throws: (any Error).self) { try db.save([c]) }
    #expect(try db.load().first?.title == "Keep all constraints")
    #expect(try db.load().first?.entries.count == 2)
}

@Test func endpointNamespacesAndAppendOnlyRefresh() throws {
    var c = fixture(); c.migrateEndpoints()
    let source = try #require(c.sourceEndpoint)
    let differentProfile = NativeEndpoint(provider: source.provider, surface: source.surface,
        storeNamespace: "other-profile", nativeThreadID: source.nativeThreadID)
    #expect(source.id != differentProfile.id)
    let managed = c.attachManagedEndpoint(nativeID: "third-session")
    #expect(c.nativeEndpoints.count == 3)
    var a = Entry(kind: .user, text: "same text"); a.nativeItemID = "native-a"
    var b = Entry(kind: .user, text: "same text"); b.nativeItemID = "native-b"
    var local = Entry(kind: .assistant, text: "Runtime contribution"); local.endpointID = managed.id
    let initial = HistoryReconciler.merge([a,b], endpoint: source, into: [local])
    let replayed = HistoryReconciler.merge([a,b], endpoint: source, into: initial)
    #expect(replayed.count == 3)
    #expect(replayed.map(\.id) == initial.map(\.id))
    a.text = "corrected native text"
    let partial = HistoryReconciler.merge([a], endpoint: source, into: replayed)
    #expect(partial.count == 3)
    #expect(partial[0].text == "Runtime contribution")
    #expect(partial[1].text == "corrected native text")
    #expect(partial[2].text == "same text")
}

@Test func indexedSearchTracksEditsAndSurvivesPartialSnapshots() throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let db = try ContinuityDatabase(directory: root)
    var c = fixture(); try db.save([c])
    #expect(try db.search("fixtures").map(\.conversationID) == [c.id])
    c.entries[0].text = "Preserve binary artifacts"; try db.save([c])
    #expect(try db.search("fixtures").isEmpty)
    #expect(try db.search("binary artifacts").count == 1)
    c.entries = []; try db.save([c])
    #expect(try db.load().first?.entries.count == 2)
    #expect(try db.search("\" OR *").isEmpty)
}

@Test func deliveryJournalDeduplicatesAndReconcilesCrash() throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let db = try ContinuityDatabase(directory: root)
    var c = fixture(); c.migrateEndpoints(); try db.save([c])
    let endpoint = try #require(c.sourceEndpoint)
    let intent = Delivery(principal: "test", idempotencyKey: "one-operation", endpointID: endpoint.id, message: "Do this once")
    let first = try db.enqueue(intent)
    let duplicate = Delivery(principal: "test", idempotencyKey: "one-operation", endpointID: endpoint.id, message: "Do this once")
    #expect(try db.enqueue(duplicate).id == first.id)
    var collision = duplicate; collision.message = "Different work"
    #expect(throws: (any Error).self) { try db.enqueue(collision) }
    _ = try db.transition(first.id, to: .dispatching)
    let reopened = try ContinuityDatabase(directory: root)
    #expect(try reopened.recoverDispatches().map(\.state) == [.unknown])
    #expect(try reopened.recoverDispatches().isEmpty)
    #expect(throws: (any Error).self) { try reopened.transition(first.id, to: .dispatching) }
    #expect(throws: (any Error).self) { try reopened.transition(first.id, to: .accepted) }
    let wrong = DeliveryReceipt(endpointID: endpoint.id, nativeThreadID: "wrong-native-id", evidence: "receipt")
    #expect(throws: (any Error).self) { try reopened.transition(first.id, to: .accepted, receipt: wrong) }
    let receipt = DeliveryReceipt(endpointID: endpoint.id, nativeThreadID: endpoint.nativeThreadID, evidence: "native-observed-turn")
    #expect(try reopened.transition(first.id, to: .accepted, receipt: receipt).state == .accepted)
    #expect(try reopened.enqueue(duplicate).state == .accepted)
    #expect(try reopened.transition(first.id, to: .nativeObserved, receipt: receipt).state == .nativeObserved)
    #expect(throws: (any Error).self) { try reopened.transition(first.id, to: .dispatching) }
}

@Test func cursorUsesISOTimeAndStableNativeIdentity() throws {
    let a = try #require(NativeHistoryDecoder.cursorEntry(key: "bubble:one", data: Data(
        #"{"type":1,"text":"hello","createdAt":"2026-10-01T01:39:10.464Z"}"#.utf8)))
    let b = try #require(NativeHistoryDecoder.cursorEntry(key: "bubble:two", data: Data(
        #"{"type":2,"text":"hello","createdAt":1790818751464}"#.utf8)))
    #expect(a.createdAt < b.createdAt)
    #expect(a.nativeItemID == "bubble:one")
    #expect(a.id != b.id)
    #expect(a.createdAt != .distantPast)
}

@Test func largeContextIsFullyRetrievable() throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    var c = fixture(); c.migrateEndpoints()
    c.entries.append(.init(kind: .tool, text: String(repeating: "binary output info ", count: 6000)))
    let prompt = try ContextArchive.prepare(conversation: c, request: "continue", directory: root)
    #expect(prompt.contains("Read the context archive before acting"))
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    let archive = try JSONDecoder().decode(ContextArchive.self, from: Data(contentsOf: #require(files.first)))
    #expect(archive.entries.map(\.text) == c.entries.map(\.text))
    #expect(archive.completeness == .partial)
}

@Test func buildChangesDraftsAndUnboundAccountsPreventDesktopDispatch() throws {
    let endpoint = NativeEndpoint(provider: .cursor, surface: .cursorAgentsWindow, storeNamespace: "test", nativeThreadID: "id", workingDirectory: "/tmp/project")
    let capabilities = [DesktopCapability.sendExistingThread, .wakeIdleThread, .callerBinding].map {
        CapabilityEvidence($0, support: .verified, appBuild: "1", testRunID: "fixture-only", detail: "synthetic")
    }
    var binding = DesktopBinding(endpoint: endpoint, appBuild: "1", accountVerified: true,
        workspaceVerified: true, nativeThreadVerified: true, hasDraft: false, isBusy: false,
        sourceRevision: "r1", capabilities: capabilities)
    try binding.requireSend(expectedRevision: "r1")
    binding.appBuild = "2"
    #expect(throws: (any Error).self) { try binding.requireSend(expectedRevision: "r1") }
    binding.appBuild = "1"; binding.hasDraft = true
    #expect(throws: (any Error).self) { try binding.requireSend(expectedRevision: "r1") }
    binding.hasDraft = false; binding.accountVerified = false
    #expect(throws: (any Error).self) { try binding.requireSend(expectedRevision: "r1") }
    binding.accountVerified = true
    #expect(throws: (any Error).self) { try binding.requireSend(expectedRevision: "stale") }
}

private actor ProbeAdapter: DesktopSurfaceAdapter {
    var sends = 0
    let endpoint: NativeEndpoint
    init(endpoint: NativeEndpoint) { self.endpoint = endpoint }
    func inspectBinding(endpoint: NativeEndpoint) async throws -> DesktopBinding {
        .init(endpoint: endpoint, appBuild: "test", accountVerified: true, workspaceVerified: true,
              nativeThreadVerified: true, hasDraft: false, isBusy: false, sourceRevision: "r1",
              capabilities: [DesktopCapability.sendExistingThread, .wakeIdleThread, .callerBinding].map {
            CapabilityEvidence($0, support: .verified, appBuild: "test", testRunID: "synthetic", detail: "fixture")
        })
    }
    func send(_ delivery: Delivery, binding: DesktopBinding) async throws -> NativeSendOutcome {
        sends += 1
        throw ShastraError.processExited("Receipt lost after possible acceptance")
    }
    func reconcile(_ delivery: Delivery) async throws -> NativeSendOutcome {
        .accepted(.init(endpointID: endpoint.id, nativeThreadID: endpoint.nativeThreadID, evidence: "Observed operation marker"))
    }
    func openNative(_ endpoint: NativeEndpoint) async throws { }
}

@Test func coordinatorNeverReplaysUnknownAcceptance() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let db = try ContinuityDatabase(directory: root)
    var c = Conversation(provider: .cursor, workingDirectory: "/tmp/project")
    let endpoint = NativeEndpoint(provider: .cursor, surface: .cursorAgentsWindow, storeNamespace: "fixture", nativeThreadID: "native", workingDirectory: "/tmp/project")
    c.endpoints = [endpoint]; try db.save([c])
    let adapter = ProbeAdapter(endpoint: endpoint)
    let coordinator = ConversationCoordinator(database: db)
    let intent = Delivery(principal: "test", idempotencyKey: "send", endpointID: endpoint.id, expectedRevision: "r1", message: "one turn")
    #expect(try await coordinator.send(intent, endpoint: endpoint, adapter: adapter).state == .unknown)
    #expect(try await coordinator.send(intent, endpoint: endpoint, adapter: adapter).state == .unknown)
    #expect(await adapter.sends == 1)
    let next = Delivery(principal: "test", idempotencyKey: "another", endpointID: endpoint.id, expectedRevision: "r1", message: "another turn")
    do { _ = try await coordinator.send(next, endpoint: endpoint, adapter: adapter); Issue.record("Unknown acceptance must block subsequent sends") }
    catch { }
    #expect(await adapter.sends == 1)
    #expect(try await coordinator.reconcile(intent.id, adapter: adapter).state == .accepted)
    #expect(try await coordinator.send(intent, endpoint: endpoint, adapter: adapter).state == .accepted)
    #expect(await adapter.sends == 1)
}

@Test func nativeResumePreservesSourceEndpointAndRejectsIdentityChanges() throws {
    var chat = Conversation(provider: .codex, workingDirectory: "/tmp/project")
    chat.sourceIdentity = "codex:original"; chat.vendorSessionID = "original"
    chat.migrateEndpoints()
    let endpoint = try #require(chat.resumeEndpoint)
    let conversationID = chat.id
    try chat.validateResumeAccount()
    let resumed = try chat.recordResumedEndpoint(nativeID: "original")
    #expect(resumed.id == endpoint.id); #expect(resumed.ownership == .managed)
    #expect(chat.nativeEndpoints.count == 1); #expect(chat.id == conversationID)
    #expect(chat.sourceEndpoint?.nativeThreadID == "original")
    #expect(throws: (any Error).self) { try chat.recordResumedEndpoint(nativeID: "replacement") }
    chat.accountID = UUID()
    #expect(throws: (any Error).self) { try chat.validateResumeAccount() }
    chat.provider = .claude
    #expect(chat.resumeEndpoint == nil)
}

@Test func cursorDesktopHistoryCannotBeSilentlyRecreatedAsCLIChat() throws {
    var chat = Conversation(provider: .cursor, workingDirectory: "/tmp/project")
    chat.sourceIdentity = "cursor-editor:desktop-thread"; chat.sourceKind = "Cursor Editor"
    chat.vendorSessionID = "desktop-thread"; chat.migrateEndpoints()
    #expect(chat.nativeResumeUnavailableReason != nil)
    #expect(throws: (any Error).self) { try chat.validateResumeAccount() }
    #expect(chat.resumeEndpoint?.nativeThreadID == "desktop-thread")
    #expect(chat.nativeEndpoints.count == 1)
    chat.provider = .codex
    #expect(chat.nativeResumeUnavailableReason == nil) // Explicit provider change is a separate session.
}
