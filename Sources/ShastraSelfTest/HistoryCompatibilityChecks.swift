import Foundation
import ShastraCore

func verifyHistoryCompatibility() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "shastra-history-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID().uuidString.lowercased()
    let directory = root.appending(path: "sessions/2026/09/30")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "rollout-2026-09-30T12-00-00-\(id).jsonl")
    func record(_ type: String, _ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["timestamp": "2026-09-30T12:00:00.000Z", "type": type, "payload": payload])
        return String(decoding: data, as: UTF8.self) + "\n"
    }
    let user: [String: Any] = ["type": "UserMessage", "id": "user1", "content": [["type": "Text", "text": "Fix this"]]]
    let agent: [String: Any] = ["type": "AgentMessage", "id": "agent1", "content": [["type": "Text", "text": "Fixed"]], "phase": "final_answer"]
    var transcript = try record("session_meta", ["id": id])
    transcript += try record("response_item", ["type": "message", "role": "developer", "content": [["type": "input_text", "text": "Internal instructions"]]])
    transcript += try record("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Fix this"]]])
    transcript += try record("event_msg", ["type": "item_completed", "item": user])
    transcript += try record("event_msg", ["type": "item_completed", "item": ["type": "FunctionCallOutput", "id": "output1", "output": "New incompatible item"]])
    transcript += try record("event_msg", ["type": "item_completed", "item": ["type": "CommandExecution", "id": "tool1", "command": "swift build"]])
    transcript += try record("event_msg", ["type": "item_completed", "item": agent])
    transcript += try record("event_msg", ["type": "item_completed", "item": agent])
    transcript += "{\"partiallyWritten\":"
    try transcript.write(to: file, atomically: true, encoding: .utf8)
    let entries = try CodexRolloutHistory.read(sessionID: id, root: root)
    precondition(entries.map(\.text) == ["Fix this", "swift build", "Fixed"])
    precondition(entries.map(\.kind) == [.user, .tool, .assistant])
    precondition(entries[0].createdAt.timeIntervalSince1970 > 0)

    let older = UUID().uuidString.lowercased()
    let archive = root.appending(path: "archived_sessions")
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    var oldText = try record("session_meta", ["session_id": older])
    oldText += try record("event_msg", ["type": "user_message", "message": "Old question"])
    oldText += try record("event_msg", ["type": "agent_message", "message": "Old answer"])
    try oldText.write(to: archive.appending(path: "rollout-\(older).jsonl"), atomically: true, encoding: .utf8)
    let oldEntries = try CodexRolloutHistory.read(sessionID: older, root: root)
    precondition(oldEntries.map(\.text) == ["Old question", "Old answer"])

    let wrongID = UUID().uuidString.lowercased()
    try transcript.write(to: directory.appending(path: "rollout-\(wrongID).jsonl"), atomically: true, encoding: .utf8)
    do {
        _ = try CodexRolloutHistory.read(sessionID: wrongID, root: root)
        throw ShastraError.invalidResponse("Reader accepted a mismatched session")
    } catch ShastraError.invalidResponse(let text) {
        precondition(text.contains("unavailable"))
    }
    print("History compatibility checks passed")
}
