import Foundation
import Testing
@testable import ShastraCore

private func collaborationFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "shastra-collaboration-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
@Test func annotationsUseExactUnicodeRangesAndRejectChangedSources() throws {
    let source = UUID(), entry = Entry(kind: .assistant, text: "one 😀 श repeated repeated")
    let range = (entry.text as NSString).range(of: "श repeated")
    let anchor = try MessageAnchor(sourceID: source, entry: entry, range: range)
    #expect(anchor.quote == "श repeated")
    #expect(anchor.matches(entry))
    var changed = entry; changed.text += "!"
    #expect(!anchor.matches(changed))
    #expect(throws: (any Error).self) { try MessageAnchor(sourceID: source, entry: entry, range: NSRange(location: 5, length: 1)) }
    #expect(throws: (any Error).self) { try MessageAnchor(sourceID: source, entry: entry, range: NSRange(location: Int.max, length: 4)) }
}
@Test func collaborationPersistsAndDetectsConcurrentEditsWithoutResettingHistory() throws {
    let root = try collaborationFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let first = try ContinuityDatabase(directory: root), second = try ContinuityDatabase(directory: root)
    var context = ProjectContext(id: "/project/.git"); context.instructions = "Use native SwiftUI"; context.decisions = ["Keep account context separate"]
    let saved = try first.saveProjectContext(context)
    #expect(saved.revision == 1)
    #expect(try second.projectContext(context.id) == saved)
    #expect(throws: (any Error).self) { try second.saveProjectContext(context) }
    var another = ProjectContext(id: "/other/.git"); another.instructions = "Other instructions"
    _ = try second.saveProjectContext(another)
    let entry = Entry(kind: .assistant, text: "Keep this exact passage")
    let anchor = try MessageAnchor(sourceID: UUID(), entry: entry, range: NSRange(location: 0, length: 9))
    var annotation = ChatAnnotation(projectID: context.id, anchor: anchor, comment: "Clarify it")
    annotation = try first.saveAnnotation(annotation)
    var stale = annotation; stale.resolved = true
    annotation.comment = "A better clarification"; _ = try second.saveAnnotation(annotation)
    #expect(throws: (any Error).self) { try first.saveAnnotation(stale) }
    let reopened = try ContinuityDatabase(directory: root).collaborationSnapshot()
    #expect(reopened.projects.count == 2)
    #expect(reopened.annotations.first?.comment == "A better clarification")
    #expect(try first.load().isEmpty)
}
@Test func forksStopAtBoundaryAndNeverReuseVendorOrEntryIdentities() throws {
    var first = Entry(kind: .user, text: "initial")
    first.endpointID = UUID(); first.nativeItemID = "private-native-item"
    let boundary = Entry(kind: .assistant, text: "answer")
    let later = Entry(kind: .user, text: "must not leak")
    let result = try ChatFork.prefix([first, boundary, later], through: boundary.id)
    #expect(result.map(\.text) == ["initial", "answer"])
    #expect(result.allSatisfy { $0.endpointID == nil && $0.nativeItemID == nil })
    #expect(Set(result.map(\.id)).isDisjoint(with: [first.id, boundary.id, later.id]))
    #expect(throws: (any Error).self) { try ChatFork.prefix([first], through: UUID()) }
}
@Test func projectContextIsScopedAcrossWorktreesAndNotOtherRepositories() async throws {
    let root = try collaborationFixture(); defer { try? FileManager.default.removeItem(at: root) }
    let repository = root.appending(path: "repo"); try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try LocalCommand.git(repository.path, ["init"])
    try LocalCommand.git(repository.path, ["config", "user.name", "Fixture"]); try LocalCommand.git(repository.path, ["config", "user.email", "fixture@example.invalid"])
    try Data("test".utf8).write(to: repository.appending(path: "file"))
    try LocalCommand.git(repository.path, ["add", "."]); try LocalCommand.git(repository.path, ["-c", "commit.gpgsign=false", "commit", "-m", "fixture"])
    let worktree = root.appending(path: "other-checkout"); try LocalCommand.git(repository.path, ["worktree", "add", "--detach", worktree.path])
    let catalog = WorkspaceIdentityCatalog(), identities = await catalog.resolve([repository.path, worktree.path])
    #expect(identities[repository.path]?.projectID == identities[worktree.path]?.projectID)
    let store = CollaborationStore(directory: root.appending(path: "data"))
    var context = ProjectContext(id: try #require(identities[repository.path]?.projectID)); context.instructions = "shared project rule"
    _ = try await store.save(context)
    #expect(try await store.prompt("question", workspace: worktree.path).contains("shared project rule"))
    #expect(try await store.prompt("question", workspace: root.path) == "question")
}
