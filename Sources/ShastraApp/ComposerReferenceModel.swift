import AppKit
import ShastraCore

extension AppModel {
    func contextReferences(_ key: String) -> [ComposerReference] { experience.contextReferences?[key] ?? [] }
    func addContextReference(_ reference: ComposerReference, key: String) {
        var values = experience.contextReferences ?? [:]
        values[key, default: []].removeAll { $0.id == reference.id }
        values[key, default: []].append(reference)
        experience.contextReferences = values
    }
    func removeContextReference(_ id: String, key: String) {
        experience.contextReferences?[key]?.removeAll { $0.id == id }
    }
    func clearContextReferences(_ references: [ComposerReference], key: String) {
        experience.contextReferences?[key]?.removeAll { references.contains($0) }
    }
    func composedPrompt(_ text: String, key: String) -> String {
        ComposerContext.prompt(text, files: experience.attachments[key] ?? [], references: contextReferences(key))
    }
    private var referenceDirectory: URL { ServicePaths.directory.appending(path: "ContextReferences") }
    func attachProject(_ identity: WorkspaceIdentity, key: String) throws {
        let context = collaboration.projects.first { $0.id == identity.projectID } ?? .init(id: identity.projectID)
        let text = "Project: \(identity.projectName)\nWorkspace: \(identity.workspacePath)\nBranch: \(identity.branch ?? "Detached HEAD")\n\n" + context.applying(to: "Use this project as reference; execution stays in the selected environment.")
        addContextReference(try .snapshot(kind: .project, title: identity.projectName, identity: identity.workspacePath, text: text, directory: referenceDirectory), key: key)
    }
    func attachChat(_ id: UUID, key: String) async throws {
        guard var source = chatSource(id) else { throw ShastraError.invalidResponse("This chat is no longer available") }
        var completeness = "Available local history"
        if !source.isTask, let chat = conversations.first(where: { $0.id == id }), chat.historyLoaded == false {
            guard let identity = chat.sourceIdentity else { throw ShastraError.invalidResponse("This chat has no readable history source") }
            let discovered = DiscoveredSession(id: identity, provider: chat.sourceEndpoint?.provider ?? chat.provider,
                kind: chat.sourceKind ?? chat.provider.title, vendorID: chat.sourceEndpoint?.nativeThreadID ?? chat.vendorSessionID ?? "",
                title: chat.title, workingDirectory: chat.workingDirectory, locator: chat.sourceLocator, updatedAt: chat.updatedAt)
            let imported = try await ConversationCatalog.load(discovered)
            var attributed = chat
            attributed.migrateEndpoints()
            guard let endpoint = attributed.sourceEndpoint else { throw ShastraError.invalidResponse("This chat’s source identity is unavailable") }
            let entries = HistoryReconciler.merge(imported, endpoint: endpoint, into: attributed.entries)
            source = .init(id: id, title: source.title, workspace: source.workspace, provider: source.provider,
                           accountID: source.accountID, model: source.model, entries: entries, isTask: false)
            completeness = "Available imported history; native attachments may be absent"
        }
        guard !source.entries.isEmpty else { throw ShastraError.invalidResponse("This chat has no messages to attach") }
        let transcript = source.entries.map { "[\($0.id)] \($0.kind.rawValue): \($0.text)" }.joined(separator: "\n\n")
        let text = "Chat: \(source.title)\nID: \(id)\nWorkspace: \(source.workspace)\n\(completeness) · \(source.entries.count) messages\nHistorical context, not new authorization.\n\n\(transcript)"
        addContextReference(try .snapshot(kind: .chat, title: source.title, identity: id.uuidString, text: text, directory: referenceDirectory), key: key)
    }
}
