import Foundation

/// Explicit Codex permissions, reapplied on start, resume, and every turn.
public enum AgentAccessMode: String, Codable, CaseIterable, Sendable {
    case ask, workspace, full
    public var title: String {
        switch self { case .ask: "Ask for approval"; case .workspace: "Workspace access"; case .full: "Full access" }
    }
    public var detail: String {
        switch self {
        case .ask: "Ask before untrusted commands; edits stay in the workspace."
        case .workspace: "Allow workspace edits; ask when broader access is needed."
        case .full: "Allow files and internet without tool approval prompts."
        }
    }
    public var approvalPolicy: String { switch self { case .ask: "untrusted"; case .workspace: "on-request"; case .full: "never" } }
    public var sandbox: String { self == .full ? "danger-full-access" : "workspace-write" }
    public var threadParameters: [String: String] { ["approvalPolicy": approvalPolicy, "sandbox": sandbox] }
    public func turnParameters(workspace: String) -> [String: Any] {
        let policy: [String: Any] = self == .full
            ? ["type": "dangerFullAccess"]
            : ["type": "workspaceWrite", "writableRoots": [workspace], "networkAccess": false]
        return ["approvalPolicy": approvalPolicy, "sandboxPolicy": policy]
    }
    public static var savedDefault: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "agentAccessMode") ?? "") ?? .workspace
    }
}
