import Foundation
import Testing
@testable import ShastraCore

@Test func experienceRoundTripAndLegacyConversation() throws {
    var prefs = ExperiencePreferences()
    let id = UUID()
    var organization = ChatOrganization(); organization.pinned = true; organization.archived = true; organization.unread = true; organization.title = "Renamed"
    prefs.chats[id.uuidString] = organization
    prefs.projects["repo"] = .init(provider: .codex, accountID: id, model: "custom-model", background: true)
    prefs.projectWorkspaces["repo"] = "/tmp/worktree"
    prefs.favoriteWorkspaces.insert("/tmp/worktree")
    prefs.attachments[id.uuidString] = ["/tmp/context.png"]
    let decoded = ExperiencePreferences.read(try JSONEncoder().encode(prefs))
    #expect(decoded.organization(id) == organization)
    #expect(decoded.projects["repo"] == prefs.projects["repo"])
    #expect(decoded.projectWorkspaces == prefs.projectWorkspaces)
    #expect(decoded.attachments == prefs.attachments)
    #expect(ExperiencePreferences.read(nil).chats.isEmpty)
    var chat = Conversation(provider: .codex, workingDirectory: "/tmp")
    chat.selectedModel = "my-model"
    let data = try JSONEncoder().encode(chat)
    #expect(try JSONDecoder().decode(Conversation.self, from: data).selectedModel == "my-model")
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]); legacy.removeValue(forKey: "selectedModel")
    #expect(try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: legacy)).selectedModel == nil)
}

@Test func contextAndSearchSnippetKeepUsefulText() {
    #expect(ComposerContext.prompt("hello", files: []) == "hello")
    let prompt = ComposerContext.prompt("Check this", files: ["/tmp/a b.png", "/tmp/code.swift"])
    #expect(prompt.contains("/tmp/a b.png")); #expect(prompt.contains("/tmp/code.swift"))
    let long = String(repeating: "before ", count: 80) + "NEEDLE relevant text" + String(repeating: " after", count: 80)
    let snippet = ComposerContext.snippet(long, query: "needle")
    #expect(snippet.contains("NEEDLE relevant text")); #expect(snippet.count <= 182)
    #expect(ComposerContext.snippet("short", query: "missing") == "short")
}
