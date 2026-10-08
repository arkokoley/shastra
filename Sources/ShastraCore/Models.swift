import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, cursor, claude, grok, opencode, hermes
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized == "Opencode" ? "OpenCode" : rawValue.capitalized }
    public var executable: String {
        switch self {
        case .codex: "codex"
        case .cursor: "cursor-agent"
        case .claude: "claude"
        case .grok: "grok"
        case .opencode: "opencode"
        case .hermes: "hermes"
        }
    }
    public var supportedInMVP: Bool { self == .codex || self == .cursor || self == .grok || self == .claude }
}

public enum ConversationState: String, Codable, Sendable {
    case idle, connecting, running, waitingForApproval, completed, interrupted, failed
}

public enum EntryKind: String, Codable, Sendable {
    case user, assistant, tool, status, error, continuation
}

public enum EntryProvenance: String, Codable, Sendable { case shastra, nativeObservation, managedRuntime }

public struct Entry: Identifiable, Codable, Sendable {
    public var id: UUID
    public var kind: EntryKind
    public var text: String
    public var createdAt: Date
    public var endpointID: UUID?
    public var nativeItemID: String?
    public var provenance: EntryProvenance?
    public init(kind: EntryKind, text: String, id: UUID = UUID(), createdAt: Date = .now) {
        self.id = id; self.kind = kind; self.text = text; self.createdAt = createdAt
        provenance = .shastra
    }
}

public struct Conversation: Identifiable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var provider: Provider
    public var workingDirectory: String
    public var accountID: UUID?
    public var profileDirectory: String?
    public var vendorSessionID: String?
    public var sourceIdentity: String?
    public var sourceKind: String?
    public var sourceLocator: String?
    public var historyLoaded: Bool?
    public var state: ConversationState
    public var entries: [Entry]
    public var updatedAt: Date
    public var endpoints: [NativeEndpoint]?
    public var activeEndpointID: UUID?
    public var selectedModel: String?
    public var savedDraft: String?
    public var managedContinuationEnabled: Bool?
    public var linkedWorkspaceConfirmed: Bool?
    public init(provider: Provider, workingDirectory: String, profileDirectory: String? = nil) {
        id = UUID(); title = "New conversation"; self.provider = provider
        self.workingDirectory = workingDirectory; self.profileDirectory = profileDirectory
        vendorSessionID = nil; sourceIdentity = nil; sourceKind = nil; sourceLocator = nil
        historyLoaded = nil; state = .idle; entries = []; updatedAt = .now
    }
}

public struct PendingApproval: Identifiable, Sendable {
    public let id: String
    public let conversationID: UUID
    public let method: String
    public let detail: String
    public let options: [String]
    public init(id: String, conversationID: UUID, method: String, detail: String, options: [String]) {
        self.id = id; self.conversationID = conversationID; self.method = method
        self.detail = detail; self.options = options
    }
}

public struct ProviderAvailability: Identifiable, Sendable {
    public let provider: Provider
    public let path: String?
    public var id: Provider { provider }
    public var isReady: Bool { path != nil && provider.supportedInMVP && (provider != .claude || ClaudeRuntime.isAvailable) }
}

public struct AgentQuestion: Identifiable, Sendable {
    public let prompt: String
    public let header: String
    public let options: [String]
    public let optionDescriptions: [String: String]
    public let multiSelect: Bool
    public var id: String { prompt }
    public init(prompt: String, header: String, options: [String], multiSelect: Bool, optionDescriptions: [String: String] = [:]) {
        self.prompt = prompt; self.header = header; self.options = options; self.multiSelect = multiSelect
        self.optionDescriptions = optionDescriptions
    }
}

public struct PendingQuestion: Identifiable, Sendable {
    public let id: String
    public let conversationID: UUID
    public let questions: [AgentQuestion]
    public init(id: String, conversationID: UUID, questions: [AgentQuestion]) {
        self.id = id; self.conversationID = conversationID; self.questions = questions
    }
}

public enum ShastraError: LocalizedError {
    case unsupported(String), invalidResponse(String), processExited(String), missingExecutable(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported(let detail), .invalidResponse(let detail), .processExited(let detail), .missingExecutable(let detail): detail
        }
    }
}
