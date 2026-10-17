import AppKit
import SwiftUI
import ShastraCore

struct ChatSource: Identifiable {
    let id: UUID
    let title: String
    let workspace: String
    let provider: Provider
    let accountID: UUID?
    let model: String?
    let entries: [Entry]
    let isTask: Bool
}
enum CollaborationRoute: Identifiable {
    case project(String), annotate(ChatSource, Entry), annotations(ChatSource), fork(ChatSource, Entry), compare(UUID), edit(ChatAnnotation), review(ReviewComment)
    var id: String {
        switch self {
        case .project(let path): "project-" + path
        case .annotate(let source, let entry): "annotate-\(source.id)-\(entry.id)"
        case .annotations(let source): "annotations-\(source.id)"
        case .fork(let source, let entry): "fork-\(source.id)-\(entry.id)"
        case .compare(let id): "compare-\(id)"
        case .edit(let annotation): "edit-\(annotation.id)"
        case .review(let comment): "review-\(comment.id)"
        }
    }
}
extension AppModel {
    func chatSource(_ id: UUID) -> ChatSource? {
        if let task = agentBoard.snapshot?.tasks.first(where: { $0.id == id }) {
            return .init(id: id, title: task.title, workspace: task.workspace, provider: task.provider,
                         accountID: task.accountID, model: task.model, entries: task.entries, isTask: true)
        }
        guard let chat = conversations.first(where: { $0.id == id }) else { return nil }
        return .init(id: id, title: chat.title, workspace: chat.workingDirectory, provider: chat.provider,
                     accountID: chat.accountID, model: chat.selectedModel, entries: chat.entries, isTask: false)
    }
    func projectKey(_ workspace: String) -> String { workspaceIdentities[workspace]?.projectID ?? WorkspaceIdentity.folder(workspace).projectID }
    func projectContext(_ workspace: String) -> ProjectContext {
        collaboration.projects.first { $0.id == projectKey(workspace) } ?? ProjectContext(id: projectKey(workspace))
    }
    func refreshCollaboration() async {
        do { collaboration = try await collaborationStore.load() }
        catch { notice = "Could not load project context and annotations: " + error.localizedDescription }
    }
    func openProjectContext(_ workspace: String) {
        Task { await resolveWorkspace(workspace); await refreshCollaboration(); collaborationRoute = .project(workspace) }
    }
    func saveContext(_ context: ProjectContext) async throws {
        _ = try await collaborationStore.save(context); await refreshCollaboration()
    }
    func saveAnnotation(_ value: ChatAnnotation) async throws {
        var value = value
        if value.revision == 0 {
            guard let source = chatSource(value.anchor.sourceID), let entry = source.entries.first(where: { $0.id == value.anchor.entryID }), value.anchor.matches(entry) else {
                throw ShastraError.invalidResponse("The source message changed. Reopen the annotation and select the passage again.")
            }
            await resolveWorkspace(source.workspace)
            value.projectID = projectKey(source.workspace)
        }
        _ = try await collaborationStore.save(value); await refreshCollaboration()
    }
    func rememberAnnotation(_ value: ChatAnnotation) async throws {
        var context = collaboration.projects.first { $0.id == value.projectID } ?? ProjectContext(id: value.projectID)
        let decision = value.comment + " (Reference: \(value.anchor.quote))"
        if !context.decisions.contains(decision) { context.decisions.append(decision) }
        try await saveContext(context)
    }
    func prepareFeedback(_ annotations: [ChatAnnotation], source: ChatSource) {
        let text = ChatAnnotation.prompt(annotations)
        if source.isTask {
            let old = agentBoard.drafts[source.id.uuidString] ?? ""
            agentBoard.drafts[source.id.uuidString] = old.isEmpty ? text : old + "\n\n" + text
            openAgent(source.id)
        } else {
            openConversation(source.id)
            draft = draft.isEmpty ? text : draft + "\n\n" + text
        }
        collaborationRoute = nil
    }
    func runAnnotations(_ annotations: [ChatAnnotation], source: ChatSource) async throws {
        for var annotation in annotations where annotation.taskID == nil {
            guard let entry = chatSource(source.id)?.entries.first(where: { $0.id == annotation.anchor.entryID }), annotation.anchor.matches(entry) else {
                throw ShastraError.invalidResponse("An annotated message changed; review its saved quotation before starting work")
            }
            var params = ["objective": ChatAnnotation.prompt([annotation]), "title": String(annotation.comment.prefix(60)),
                          "provider": source.provider.rawValue, "workspace": source.workspace, "isolate": "true",
                          "annotationIDs": String(decoding: try JSONEncoder().encode([annotation.id]), as: UTF8.self)]
            params["accessMode"] = defaultAccessMode.rawValue
            if let id = source.accountID { params["accountID"] = id.uuidString }
            if let model = source.model { params["model"] = model }
            if source.isTask { params["parentID"] = source.id.uuidString; params["notifyParent"] = "true" }
            let result = try await agentBoard.client.request("agents.spawn", params: params, operationID: "annotation-" + annotation.id.uuidString)
            let task = try JSONDecoder().decode(AgentTask.self, from: Data(result.utf8))
            annotation.taskID = task.id
            _ = try await collaborationStore.save(annotation)
        }
        await agentBoard.refresh(); await refreshCollaboration()
    }
    func fork(source: ChatSource, entry: Entry, provider: Provider, accountID: UUID?, model: String, request: String, isolated: Bool, operationID: String) async throws {
        guard let current = chatSource(source.id)?.entries.first(where: { $0.id == entry.id }), current.text == entry.text else {
            throw ShastraError.invalidResponse("The source message changed. Reopen the fork before continuing.")
        }
        var params = ["accessMode": defaultAccessMode.rawValue, "sourceID": source.id.uuidString, "entryID": entry.id.uuidString,
                      "sourceTitle": source.title, "workspace": source.workspace,
                      "provider": provider.rawValue, "objective": request, "title": "Fork: " + String(source.title.prefix(50)),
                      "isolate": String(isolated), "sourceDigest": StableIdentity.hash(entry.text)]
        if !source.isTask { params["sourceEntries"] = String(decoding: try JSONEncoder().encode(source.entries), as: UTF8.self) }
        if let accountID { params["accountID"] = accountID.uuidString } else { params["useCurrentAccount"] = "true" }
        if !model.isEmpty { params["model"] = model }
        let result = try await agentBoard.client.request("agents.fork", params: params, operationID: operationID)
        let task = try JSONDecoder().decode(AgentTask.self, from: Data(result.utf8))
        await agentBoard.refresh(); collaborationRoute = nil; openAgent(task.id)
    }
    func bringBack(_ task: AgentTask) {
        guard let origin = task.forkOrigin, let source = chatSource(origin.sourceID),
              let answer = task.result ?? task.entries.dropFirst(origin.inheritedCount).last(where: { $0.kind == .assistant })?.text else {
            notice = "The original chat or fork result is unavailable."; return
        }
        let text = "Result from fork \(task.id) (\(task.provider.title)), branching at message \(origin.entryID):\n\n" + answer
        if source.isTask {
            let old = agentBoard.drafts[source.id.uuidString] ?? ""
            agentBoard.drafts[source.id.uuidString] = old.isEmpty ? text : old + "\n\n" + text
            openAgent(source.id)
        } else {
            openConversation(source.id); draft = draft.isEmpty ? text : draft + "\n\n" + text
        }
        collaborationRoute = nil
    }
    func saveReview(_ comment: ReviewComment) async throws { _ = try await collaborationStore.save(comment); await refreshCollaboration() }
    func prepareReviewFeedback(_ comment: ReviewComment) {
        guard let source = chatSource(comment.sourceID) else { notice = "The originating chat is unavailable."; return }
        if source.isTask {
            let old = agentBoard.drafts[source.id.uuidString] ?? ""
            agentBoard.drafts[source.id.uuidString] = old.isEmpty ? comment.prompt : old + "\n\n" + comment.prompt
            openAgent(source.id)
        } else { openConversation(source.id); draft = draft.isEmpty ? comment.prompt : draft + "\n\n" + comment.prompt }
        collaborationRoute = nil
    }
}
