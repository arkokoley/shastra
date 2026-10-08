import AppKit
import SwiftUI
import ShastraCore

@MainActor final class AgentBoardModel: ObservableObject {
    @Published var organization: [String: ChatOrganization] = [:]
    var onActivity: ((UUID) -> Void)?
    @Published var snapshot: AgentServiceSnapshot?
    @Published var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedAgentTask") }
    }
    @Published var error: String?
    @Published var connected = false
    @Published var busy = false
    @Published var search = ""
    @Published var filter = "All"
    @Published var drafts: [String: String] = UserDefaults.standard.dictionary(forKey: "agentTaskDrafts") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(drafts, forKey: "agentTaskDrafts") }
    }
    let client = AgentServiceClient()
    private var polling: Task<Void, Never>?
    var selected: AgentTask? { snapshot?.tasks.first { $0.id == selectedID } }
    var attentionCount: Int { snapshot?.tasks.filter { !$0.archived && ($0.column == .needsInput || !$0.approvals.isEmpty) }.count ?? 0 }
    var tasks: [AgentTask] {
        (snapshot?.tasks ?? []).filter { task in
            (filter == "Archived" ? task.archived || organization[task.id.uuidString]?.archived == true : !task.archived && organization[task.id.uuidString]?.archived != true) &&
            (filter != "Running" || task.status.isActive || task.status == .queued) &&
            (filter != "Inbox" || task.column == .needsInput || !task.approvals.isEmpty) &&
            (search.isEmpty || (organization[task.id.uuidString]?.title ?? task.title).localizedCaseInsensitiveContains(search) || task.objective.localizedCaseInsensitiveContains(search) || task.entries.contains { $0.text.localizedCaseInsensitiveContains(search) })
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func start() {
        guard polling == nil else { return }
        selectedID = UserDefaults.standard.string(forKey: "selectedAgentTask").flatMap(UUID.init(uuidString:))
        polling = Task {
            do { try await client.ensureRunning() } catch { self.error = error.localizedDescription }
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func refresh() async {
        do {
            let value = try await client.snapshot()
            if snapshot?.revision != value.revision {
                if let snapshot {
                    for task in value.tasks where !task.archived && (task.status == .needsInput || [.completed, .failed, .interrupted].contains(task.status)) {
                        if let old = snapshot.tasks.first(where: { $0.id == task.id }), old.status != task.status { onActivity?(task.id) }
                    }
                }
                ExperienceNotifications.shared.observe(value.tasks); snapshot = value
            }
            connected = true
        } catch { connected = false }
    }
    func perform(_ method: String, params: [String: String], selectResult: Bool = false, onSuccess: (@MainActor () -> Void)? = nil) {
        let operationID = UUID().uuidString
        busy = true
        Task {
            do {
                let result = try await client.request(method, params: params, operationID: operationID)
                if selectResult { selectedID = try JSONDecoder().decode(AgentTask.self, from: Data(result.utf8)).id }
                await refresh(); onSuccess?()
            } catch { self.error = "\(error.localizedDescription)\nOperation: \(operationID). If the connection was lost, inspect the task before retrying." }
            busy = false
        }
    }
    func send(_ task: AgentTask, files: [String] = [], completed: (() -> Void)? = nil) {
        let draft = drafts[task.id.uuidString] ?? ""
        let text = ComposerContext.prompt(draft, files: files)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        perform("agents.send", params: ["taskID": task.id.uuidString, "message": text]) { [weak self] in
            if self?.drafts[task.id.uuidString] == draft { self?.drafts[task.id.uuidString] = ""; completed?() }
        }
    }
}
