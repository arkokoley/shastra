import Foundation

public struct DiscoveredSession: Identifiable, Sendable {
    public let id: String
    public let provider: Provider
    public let kind: String
    public let vendorID: String
    public let title: String
    public let workingDirectory: String
    public let locator: String?
    public let updatedAt: Date

    public init(id: String, provider: Provider, kind: String, vendorID: String, title: String,
                workingDirectory: String, locator: String?, updatedAt: Date) {
        self.id = id; self.provider = provider; self.kind = kind; self.vendorID = vendorID
        self.title = title; self.workingDirectory = workingDirectory; self.locator = locator; self.updatedAt = updatedAt
    }

    public func placeholder() -> Conversation {
        var conversation = Conversation(provider: provider, workingDirectory: workingDirectory)
        conversation.title = title
        conversation.vendorSessionID = vendorID
        conversation.sourceIdentity = id
        conversation.sourceKind = kind
        conversation.sourceLocator = locator
        conversation.historyLoaded = false
        conversation.updatedAt = updatedAt
        conversation.migrateEndpoints()
        return conversation
    }
}

public enum ConversationCatalog {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    public static func discover() async -> [DiscoveredSession] {
        let local = Task.detached(priority: .utility) {
            discoverCursorEditor() + discoverCursorCLI() + discoverClaude() + discoverGrok()
        }
        let codex = (try? await CodexHistory.list(limit: 5000)) ?? []
        let codexSessions = codex.map {
            DiscoveredSession(id: "codex:\($0.id)", provider: .codex, kind: "Codex",
                              vendorID: $0.id, title: $0.title,
                              workingDirectory: $0.workingDirectory, locator: nil,
                              updatedAt: $0.updatedAt)
        }
        return (codexSessions + (await local.value)).sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func load(_ source: DiscoveredSession) async throws -> [Entry] {
        switch source.kind {
        case "Codex":
            let codex = ImportableSession(id: source.vendorID, title: source.title,
                                          workingDirectory: source.workingDirectory,
                                          updatedAt: source.updatedAt)
            return try await CodexHistory.read(codex).entries
        case "Cursor Editor":
            return try await Task.detached(priority: .utility) { try loadCursorEditor(source) }.value
        case "Cursor CLI":
            return try await Task.detached(priority: .utility) { try loadCursorCLI(source) }.value
        case "Claude Code":
            return try await Task.detached(priority: .utility) { try loadClaude(source) }.value
        case "Grok":
            return try await Task.detached(priority: .utility) { try loadGrok(source) }.value
        default: throw ShastraError.unsupported("History reader for \(source.kind) is unavailable")
        }
    }

    private static func discoverCursorEditor() -> [DiscoveredSession] {
        let path = home.appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        guard FileManager.default.fileExists(atPath: path), let db = try? SQLiteReadOnly(path: path) else { return [] }
        var workspaceFolders: [String: String] = [:]
        let storage = home.appending(path: "Library/Application Support/Cursor/User/workspaceStorage")
        for folder in (try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? [] {
            if let data = try? Data(contentsOf: folder.appending(path: "workspace.json")),
               let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let uri = metadata["folder"] as? String,
               let url = URL(string: uri), url.isFileURL {
                workspaceFolders[folder.lastPathComponent] = url.path
            }
        }
        var results: [DiscoveredSession] = []
        try? db.rows("SELECT composerId, lastUpdatedAt, createdAt, value FROM composerHeaders") { row in
            guard let id = SQLiteReadOnly.text(row, 0), let value = SQLiteReadOnly.text(row, 3),
                  let json = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { return }
            guard (json["isDraft"] as? Bool) != true, (json["isEphemeral"] as? Bool) != true else { return }
            let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (json["subtitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Cursor editor chat"
            let workspace = json["workspaceIdentifier"] as? [String: Any]
            let cwd: String
            if let uri = workspace?["uri"] as? String, let url = URL(string: uri), url.isFileURL {
                cwd = url.path
            } else if let uri = workspace?["uri"] as? [String: Any], uri["scheme"] as? String == "file",
                      let path = (uri["fsPath"] as? String) ?? (uri["path"] as? String), path.hasPrefix("/") {
                cwd = path
            } else {
                cwd = (workspace?["id"] as? String).flatMap { workspaceFolders[$0] } ?? home.path
            }
            let rawTime = SQLiteReadOnly.int(row, 1) == 0 ? SQLiteReadOnly.int(row, 2) : SQLiteReadOnly.int(row, 1)
            results.append(.init(id: "cursor-editor:\(id)", provider: .cursor, kind: "Cursor Editor",
                                 vendorID: id, title: String(name.prefix(100)), workingDirectory: cwd,
                                 locator: path, updatedAt: Date(timeIntervalSince1970: Double(rawTime) / 1000)))
        }
        return results
    }

    private static func loadCursorEditor(_ source: DiscoveredSession) throws -> [Entry] {
        guard let path = source.locator else { return [] }
        let db = try SQLiteReadOnly(path: path)
        var messages: [Entry] = []
        try db.rows("SELECT key,value FROM cursorDiskKV WHERE key LIKE ?", bindings: ["bubbleId:\(source.vendorID):%"] ) { row in
            guard let key = SQLiteReadOnly.text(row, 0), let data = SQLiteReadOnly.data(row, 1),
                  let entry = NativeHistoryDecoder.cursorEntry(key: key, data: data) else { return }
            messages.append(entry)
        }
        return messages.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return ($0.nativeItemID ?? "") < ($1.nativeItemID ?? "")
        }
    }

    private static func discoverCursorCLI() -> [DiscoveredSession] {
        let root = home.appending(path: ".cursor/chats")
        guard let projects = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var results: [DiscoveredSession] = []
        for project in projects {
            guard let chats = try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil) else { continue }
            for chat in chats {
                let path = chat.appending(path: "store.db").path
                guard FileManager.default.fileExists(atPath: path), let db = try? SQLiteReadOnly(path: path) else { continue }
                try? db.rows("SELECT value FROM meta WHERE key = '0'") { row in
                    guard let hex = SQLiteReadOnly.text(row, 0), let data = Data(hexString: hex),
                          let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let id = meta["agentId"] as? String else { return }
                    let name = (meta["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Cursor CLI chat"
                    let created = Double((meta["createdAt"] as? Int64) ?? 0) / 1000
                    let modification = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
                    results.append(.init(id: "cursor-cli:\(id)", provider: .cursor, kind: "Cursor CLI",
                                         vendorID: id, title: String(name.prefix(100)),
                                         workingDirectory: home.path, locator: path,
                                         updatedAt: modification ?? Date(timeIntervalSince1970: created)))
                }
            }
        }
        return results
    }

    private static func loadCursorCLI(_ source: DiscoveredSession) throws -> [Entry] {
        guard let path = source.locator else { return [] }
        let db = try SQLiteReadOnly(path: path)
        var entries: [Entry] = []
        try db.rows("SELECT data,rowid FROM blobs ORDER BY rowid") { row in
            guard let data = SQLiteReadOnly.data(row, 0),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let role = json["role"] as? String, role == "user" || role == "assistant" else { return }
            let content = json["content"]
            let text: String
            if let value = content as? String { text = value }
            else if let parts = content as? [[String: Any]] {
                text = parts.filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else { return }
            if !text.isEmpty {
                var entry = Entry(kind: role == "user" ? .user : .assistant, text: text, createdAt: .distantPast)
                entry.nativeItemID = "blob:\(SQLiteReadOnly.int(row, 1))"
                entries.append(entry)
            }
        }
        return entries
    }

    private static func discoverClaude() -> [DiscoveredSession] {
        let root = home.appending(path: ".claude/projects")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var results: [DiscoveredSession] = []
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            let id = file.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: id) != nil else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            results.append(.init(id: "claude:\(id)", provider: .claude, kind: "Claude Code",
                                 vendorID: id, title: "Claude Code conversation", workingDirectory: home.path,
                                 locator: file.path, updatedAt: modified))
        }
        return results
    }

    private static func loadClaude(_ source: DiscoveredSession) throws -> [Entry] {
        guard let path = source.locator else { return [] }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var entries: [Entry] = []
        for (offset, line) in text.split(separator: "\n").enumerated() {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let role = json["type"] as? String, role == "user" || role == "assistant",
                  let message = json["message"] as? [String: Any] else { continue }
            let content = message["content"]
            let body: String
            if let value = content as? String { body = value }
            else if let parts = content as? [[String: Any]] {
                body = parts.filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else { continue }
            if !body.isEmpty {
                var entry = Entry(kind: role == "user" ? .user : .assistant, text: body,
                                  createdAt: NativeHistoryDecoder.date(json["timestamp"]))
                entry.nativeItemID = (json["uuid"] as? String) ?? "line:\(offset)"
                entries.append(entry)
            }
        }
        return entries
    }

    private static func discoverGrok() -> [DiscoveredSession] {
        let root = home.appending(path: ".grok/sessions")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var results: [DiscoveredSession] = []
        for case let file as URL in enumerator where file.lastPathComponent == "summary.json" {
            guard let data = try? Data(contentsOf: file),
                  let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let info = summary["info"] as? [String: Any] ?? [:]
            let id = (info["id"] as? String) ?? file.deletingLastPathComponent().lastPathComponent
            let cwd = (info["cwd"] as? String) ?? home.path
            let title = (summary["session_summary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Grok conversation"
            let dateText = (summary["last_active_at"] as? String) ?? (summary["updated_at"] as? String) ?? ""
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let updated = formatter.date(from: dateText)
                ?? (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let locator = file.deletingLastPathComponent().appending(path: "chat_history.jsonl").path
            results.append(.init(id: "grok:\(id)", provider: .grok, kind: "Grok",
                                 vendorID: id, title: String(title.prefix(100)),
                                 workingDirectory: cwd, locator: locator, updatedAt: updated))
        }
        return results
    }

    private static func loadGrok(_ source: DiscoveredSession) throws -> [Entry] {
        guard let path = source.locator, FileManager.default.fileExists(atPath: path) else { return [] }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var entries: [Entry] = []
        for line in text.split(separator: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let role = json["type"] as? String, role == "user" || role == "assistant" else { continue }
            let content = json["content"]
            let body: String
            if let value = content as? String { body = value }
            else if let parts = content as? [[String: Any]] {
                body = parts.filter { ($0["type"] as? String) == "text" }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else { continue }
            if !body.isEmpty { entries.append(.init(kind: role == "user" ? .user : .assistant, text: body)) }
        }
        return entries
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
