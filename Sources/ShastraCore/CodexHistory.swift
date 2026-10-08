import Foundation

public struct ImportableSession: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let workingDirectory: String
    public let updatedAt: Date
    public init(id: String, title: String, workingDirectory: String, updatedAt: Date) {
        self.id = id; self.title = title; self.workingDirectory = workingDirectory; self.updatedAt = updatedAt
    }
}

public enum CodexHistory {
    private static func connection() throws -> JSONRPCProcess {
        guard let executable = ExecutableLocator.locate("codex") else {
            throw ShastraError.missingExecutable("codex is not installed")
        }
        return try JSONRPCProcess(executable: executable, arguments: ["app-server"],
                                  workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    private static func initialize(_ rpc: JSONRPCProcess) async throws {
        _ = try await rpc.request("initialize", params: [
            "clientInfo": ["name": "shastra-history", "title": "Shastra History", "version": "0.1.0"]])
        rpc.notify("initialized")
    }

    public static func list(limit: Int = 100) async throws -> [ImportableSession] {
        let rpc = try connection()
        defer { rpc.stop() }
        try await initialize(rpc)
        var results: [ImportableSession] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = ["limit": min(100, limit - results.count)]
            if let cursor { params["cursor"] = cursor }
            let response = try await rpc.request("thread/list", params: params).value
            for thread in response["data"] as? [[String: Any]] ?? [] {
                guard let id = thread["id"] as? String else { continue }
                let title = (thread["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (thread["preview"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Codex conversation"
                let cwd = thread["cwd"] as? String ?? FileManager.default.homeDirectoryForCurrentUser.path
                let timestamp = (thread["updatedAt"] as? TimeInterval) ?? 0
                results.append(.init(id: id, title: String(title.prefix(80)),
                                     workingDirectory: cwd, updatedAt: Date(timeIntervalSince1970: timestamp)))
            }
            cursor = response["nextCursor"] as? String
        } while cursor != nil && results.count < limit
        return results
    }

    public static func read(_ source: ImportableSession) async throws -> Conversation {
        do { return try await readThroughServer(source) }
        catch {
            let entries = try await Task.detached(priority: .utility) {
                try CodexRolloutHistory.read(sessionID: source.id)
            }.value
            var conversation = Conversation(provider: .codex, workingDirectory: source.workingDirectory)
            conversation.title = source.title
            conversation.vendorSessionID = source.id
            conversation.entries = entries
            return conversation
        }
    }

    private static func readThroughServer(_ source: ImportableSession) async throws -> Conversation {
        let rpc = try connection()
        defer { rpc.stop() }
        try await initialize(rpc)
        let response = try await rpc.request("thread/read", params: [
            "threadId": source.id, "includeTurns": true]).value
        guard let thread = response["thread"] as? [String: Any] else {
            throw ShastraError.invalidResponse("Codex did not return the conversation")
        }
        var conversation = Conversation(provider: .codex, workingDirectory: source.workingDirectory)
        conversation.title = source.title
        conversation.vendorSessionID = source.id
        for turn in thread["turns"] as? [[String: Any]] ?? [] {
            for item in turn["items"] as? [[String: Any]] ?? [] {
                let previousCount = conversation.entries.count
                switch item["type"] as? String {
                case "userMessage":
                    let parts = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                    if !parts.isEmpty { conversation.entries.append(.init(kind: .user, text: parts.joined(separator: "\n"))) }
                case "agentMessage":
                    if let text = item["text"] as? String, !text.isEmpty {
                        conversation.entries.append(.init(kind: .assistant, text: text))
                    }
                case "commandExecution":
                    if let command = item["command"] as? String {
                        conversation.entries.append(.init(kind: .tool, text: command))
                    }
                default: break
                }
                if conversation.entries.count > previousCount {
                    conversation.entries[previousCount].nativeItemID = item["id"] as? String
                    conversation.entries[previousCount].createdAt = NativeHistoryDecoder.date(item["createdAt"])
                }
            }
        }
        return conversation
    }
}
