import Foundation

public enum AgentTaskStatus: String, Codable, Sendable, CaseIterable {
    case queued, starting, running, needsInput, waiting, completed, failed, interrupted, cancelled
    public var isActive: Bool { [.starting, .running, .needsInput].contains(self) }
}
public enum TaskColumn: String, Codable, Sendable, CaseIterable { case todo = "Todo", running = "Running", needsInput = "Needs input", review = "In review", done = "Done" }
public struct TaskMessage: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var sender: UUID?
    public var text: String
    public var createdAt = Date.now
    public var dispatchedAt: Date?
    public var receipt: String?
    public var state = DeliveryState.queued
    public init(text: String, sender: UUID? = nil) { self.text = text; self.sender = sender }
}
public struct TaskApproval: Identifiable, Codable, Sendable {
    public var id: String
    public var detail: String
    public var options: [String]
    public var questions: [TaskQuestion]?
}
public struct TaskQuestion: Codable, Sendable {
    public var prompt: String
    public var options: [String]
    public var multiSelect: Bool
}
public struct AgentTask: Codable, Identifiable, Sendable {
    public var id: UUID
    public var parentID: UUID?
    public var conversationID: UUID?
    public var title: String
    public var objective: String
    public var acceptance: String
    public var provider: Provider
    public var accountID: UUID?
    public var model: String?
    public var workspace: String
    public var managedWorkspaceID: UUID?
    public var dependencies: [UUID]
    public var status: AgentTaskStatus
    public var column: TaskColumn
    public var messages: [TaskMessage]
    public var entries: [Entry]
    public var approvals: [TaskApproval]
    public var nativeID: String?
    public var profileDirectory: String?
    public var result: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var archived: Bool
    public var checkpoints: [WorkspaceSnapshot]?
    public var recoveryPending: Bool?
    public var notifyParent: Bool
    public init(id: UUID = UUID(), title: String, objective: String, provider: Provider, workspace: String,
                parentID: UUID? = nil, conversationID: UUID? = nil, accountID: UUID? = nil, model: String? = nil,
                acceptance: String = "", managedWorkspaceID: UUID? = nil, dependencies: [UUID] = [], notifyParent: Bool = true) {
        self.id = id; self.title = title; self.objective = objective; self.provider = provider; self.workspace = workspace
        self.parentID = parentID; self.conversationID = conversationID; self.accountID = accountID; self.model = model
        self.acceptance = acceptance; self.managedWorkspaceID = managedWorkspaceID; self.dependencies = dependencies
        self.notifyParent = notifyParent; archived = false; status = .queued; column = .todo
        messages = [TaskMessage(text: objective)]; entries = []; approvals = []; createdAt = .now; updatedAt = .now
    }
}
public struct AgentServiceSnapshot: Codable, Sendable {
    public var revision: Int
    public var tasks: [AgentTask]
    public var workspaces: [ManagedWorkspace]
    public var maxParallel: Int
}

public struct CoordinationState: Codable, Sendable {
    public var revision = 0
    public var tasks: [AgentTask] = []
    public var grants: [String: UUID] = [:]
    public var creationRequests: [String: String]?
    public var operations: [String: UUID] = [:]
    public var maxParallel = 4
    public init() { }
}
