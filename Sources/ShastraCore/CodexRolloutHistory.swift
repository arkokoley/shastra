import Foundation

/// Read-only compatibility reader for rollouts newer than the installed app-server.
/// Unknown records are skipped without rewriting the source conversation.
public enum CodexRolloutHistory {
    public static func read(sessionID: String, root: URL? = nil) throws -> [Entry] {
        guard UUID(uuidString: sessionID) != nil else {
            throw ShastraError.invalidResponse("Invalid Codex conversation ID")
        }
        let home = root ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        for folder in ["sessions", "archived_sessions"] {
            guard let files = FileManager.default.enumerator(at: home.appending(path: folder),
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in files where file.lastPathComponent.hasSuffix("\(sessionID).jsonl") {
                if let entries = try readFile(file, sessionID: sessionID) { return entries }
            }
        }
        throw ShastraError.invalidResponse("The local Codex transcript is unavailable. Open the chat in Codex, then retry.")
    }

    private static func readFile(_ file: URL, sessionID: String) throws -> [Entry]? {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var verified = false
        var completed: [Entry] = []
        var responses: [Entry] = []
        var legacy: [Entry] = []
        var seen: Set<String> = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var lineNumber = 0
        func record(_ line: Data) {
            defer { lineNumber += 1 }
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { return }
            let date = (object["timestamp"] as? String).flatMap { formatter.date(from: $0) } ?? .distantPast
            switch object["type"] as? String {
            case "session_meta":
                verified = (payload["id"] as? String ?? payload["session_id"] as? String) == sessionID
            case "event_msg":
                if payload["type"] as? String == "item_completed", let item = payload["item"] as? [String: Any] {
                    if let id = item["id"] as? String, !seen.insert(id).inserted { return }
                    if var entry = completedEntry(item, date: date) {
                        entry.nativeItemID = item["id"] as? String ?? "rollout:\(lineNumber)"
                        completed.append(entry)
                    }
                } else if let text = payload["message"] as? String, !text.isEmpty {
                    switch payload["type"] as? String {
                    case "user_message": legacy.append(.init(kind: .user, text: text, createdAt: date))
                    case "agent_message": legacy.append(.init(kind: .assistant, text: text, createdAt: date))
                    default: break
                    }
                }
            case "response_item":
                guard payload["type"] as? String == "message",
                      payload["channel"] as? String != "analysis",
                      let role = payload["role"] as? String, ["user", "assistant"].contains(role),
                      let text = messageText(payload["content"]), !text.isEmpty else { return }
                responses.append(.init(kind: role == "user" ? .user : .assistant, text: text, createdAt: date))
            default: break
            }
        }

        // Bounded line buffering also tolerates a partially written final record.
        var buffer = Data()
        var skippingOversizedLine = false
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            var remaining = chunk[...]
            while let end = remaining.firstIndex(of: 10) {
                if !skippingOversizedLine {
                    buffer.append(contentsOf: remaining[..<end])
                    if buffer.count <= 8_388_608 { record(buffer) }
                }
                buffer = Data()
                skippingOversizedLine = false
                remaining = remaining[remaining.index(after: end)...]
            }
            if !skippingOversizedLine {
                buffer.append(contentsOf: remaining)
                if buffer.count > 8_388_608 { buffer = Data(); skippingOversizedLine = true }
            }
        }
        if !buffer.isEmpty && !skippingOversizedLine { record(buffer) }
        guard verified else { return nil }
        for index in responses.indices { responses[index].nativeItemID = "response:\(index)" }
        for index in legacy.indices { legacy[index].nativeItemID = "legacy:\(index)" }
        if completed.contains(where: { $0.kind == .user || $0.kind == .assistant }) { return completed }
        return responses.isEmpty ? legacy : responses
    }

    private static func completedEntry(_ item: [String: Any], date: Date) -> Entry? {
        switch (item["type"] as? String)?.lowercased() {
        case "usermessage":
            guard let text = messageText(item["content"]), !text.isEmpty else { return nil }
            return .init(kind: .user, text: text, createdAt: date)
        case "agentmessage":
            guard item["phase"] as? String != "analysis",
                  let text = (item["text"] as? String) ?? messageText(item["content"]), !text.isEmpty else { return nil }
            return .init(kind: .assistant, text: text, createdAt: date)
        case "commandexecution":
            guard let command = item["command"] as? String else { return nil }
            return .init(kind: .tool, text: command, createdAt: date)
        case "filechange": return .init(kind: .tool, text: "Updated files", createdAt: date)
        case "mcptoolcall":
            return .init(kind: .tool, text: [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: "/"), createdAt: date)
        default: return nil
        }
    }

    private static func messageText(_ content: Any?) -> String? {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return nil }
        return parts.compactMap { part -> String? in
            guard let type = part["type"] as? String,
                  ["text", "input_text", "output_text"].contains(type.lowercased()) else { return nil }
            return part["text"] as? String
        }.joined(separator: "\n")
    }
}
