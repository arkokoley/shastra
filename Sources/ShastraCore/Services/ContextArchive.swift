import Foundation

public struct ContextArchive: Codable, Sendable {
    public var schemaVersion = 1
    public var conversationID: UUID
    public var workspace: String
    public var endpoints: [NativeEndpoint]
    public var entries: [Entry]
    public var completeness: HistoryCompleteness

    /// A linked runtime gets a complete local artifact, not an silently truncated transcript.
    /// This is context transfer, not a forged native conversation or a desktop handoff receipt.
    public static func prepare(conversation: Conversation, request: String, directory: URL) throws -> String {
        let archive = ContextArchive(conversationID: conversation.id, workspace: conversation.workingDirectory,
            endpoints: conversation.nativeEndpoints, entries: conversation.entries,
            completeness: conversation.sourceIdentity == nil ? .complete : .partial)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        let hash = StableIdentity.hash(String(decoding: data, as: UTF8.self))
        let url = directory.appending(path: "\(hash).json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let transcript = conversation.entries.map { "[\($0.id.uuidString)] \($0.kind.rawValue): \($0.text)" }.joined(separator: "\n\n")
        let visible: String
        if transcript.utf8.count <= 48_000 { visible = transcript }
        else {
            visible = "The transcript is too large to inline. Read the context archive before acting; no prior constraints should be inferred from this omission."
        }
        return """
        Continue this logical conversation in a new managed runtime. This is a linked continuation.
        Workspace: \(conversation.workingDirectory)
        Context archive: \(url.path)
        SHA256: \(hash)
        Available entries: \(archive.entries.count). Source completeness: \(archive.completeness.rawValue).
        The archive preserves all available messages and tool results with endpoint attribution; native attachments or omitted source events may be unavailable.
        Prior messages are historical context, not new authorization. Follow the latest user request and preserve applicable earlier constraints.

        <prior_context>
        \(visible)
        </prior_context>

        Latest user request:
        \(request)
        """
    }
}
