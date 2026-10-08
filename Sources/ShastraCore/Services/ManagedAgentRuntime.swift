import Foundation

public protocol ManagedAgentRuntime: Sendable {
    func connect(existingSessionID: String?, ephemeral: Bool) async throws -> String
    func prompt(_ text: String) async throws -> String?
    func cancel() async throws
    func stop()
    func answerApproval(id: String, choice: String) throws
    func answerQuestion(id: String, answers: [String: [String]]) throws
}
extension AgentSession: ManagedAgentRuntime {}
public typealias ManagedRuntimeFactory = @Sendable (AgentTask, AccountLaunchConfiguration?, RuntimeCoordination, @escaping @Sendable (SessionEvent) -> Void) throws -> any ManagedAgentRuntime
