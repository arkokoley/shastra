import Foundation
import Testing
@testable import ShastraCore

@Test func accessModesExplicitlyOverrideStartResumeAndTurnPolicies() throws {
    #expect(AgentAccessMode.full.threadParameters == ["approvalPolicy": "never", "sandbox": "danger-full-access"])
    #expect(AgentAccessMode.ask.approvalPolicy == "untrusted")
    #expect(AgentAccessMode.workspace.approvalPolicy == "on-request")
    for mode in AgentAccessMode.allCases {
        let turn = mode.turnParameters(workspace: "/tmp/project")
        #expect(turn["approvalPolicy"] as? String == mode.approvalPolicy)
        let sandbox = try #require(turn["sandboxPolicy"] as? [String: Any])
        #expect(sandbox["type"] as? String == (mode == .full ? "dangerFullAccess" : "workspaceWrite"))
        if mode != .full {
            #expect(sandbox["writableRoots"] as? [String] == ["/tmp/project"])
            #expect(sandbox["networkAccess"] as? Bool == false)
        }
    }
}

@Test func accountSwitchKeepsChatAndTransfersHistoryWithoutReusingOtherCredentials() throws {
    var chat = Conversation(provider: .codex, workingDirectory: "/tmp/project")
    let firstAccount = UUID(), secondAccount = UUID()
    chat.accountID = firstAccount
    chat.savedDraft = "Keep going"
    chat.accessMode = .full
    let original = chat.attachManagedEndpoint(nativeID: "first-thread")
    var message = Entry(kind: .user, text: "Keep the fixtures")
    message.endpointID = original.id
    chat.entries = [message]
    let id = chat.id
    chat.switchAccount(to: secondAccount)
    try chat.validateResumeAccount()
    #expect(chat.id == id && chat.savedDraft == "Keep going")
    #expect(chat.resumeEndpoint == nil)
    #expect(chat.activeEndpoint?.accountID == firstAccount)
    #expect(chat.entries.first?.endpointID == original.id)
    let folder = FileManager.default.temporaryDirectory.appending(path: "shastra-switch-\(UUID())")
    defer { try? FileManager.default.removeItem(at: folder) }
    let prompt = try ContextArchive.prepare(conversation: chat, request: "Continue", directory: folder)
    #expect(prompt.contains("Keep the fixtures"))
    let next = chat.attachManagedEndpoint(nativeID: "second-thread")
    #expect(next.accountID == secondAccount && chat.resumeEndpoint?.id == next.id)
    chat.entries.append(.init(kind: .assistant, text: "New account result"))
    chat.switchAccount(to: firstAccount)
    #expect(chat.resumeEndpoint == nil) // Starting fresh includes work performed by both accounts.
    #expect(chat.nativeEndpoints.count == 2)
    let restored = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(chat))
    #expect(restored.entries.count == 2 && restored.accessMode == .full)
}

@Test func legacyConversationSwitchMigratesBeforeChangingAccount() throws {
    var chat = Conversation(provider: .codex, workingDirectory: "/tmp/project")
    chat.vendorSessionID = "legacy"; chat.sourceIdentity = "codex:legacy"
    chat.switchAccount(to: UUID())
    #expect(chat.sourceEndpoint?.accountID == nil)
    #expect(chat.resumeEndpoint == nil)
    try chat.validateResumeAccount()
}
