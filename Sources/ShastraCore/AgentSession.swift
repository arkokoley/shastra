import Foundation

public enum SessionEvent: Sendable {
    case messageStart, text(String), tool(String), status(ConversationState, String), approval(String, String, [String]), question(String, [AgentQuestion]), error(String)
}

public final class AgentSession: @unchecked Sendable {
    public let provider: Provider
    public let workingDirectory: String
    private let rpc: JSONRPCProcess
    private let eventHandler: @Sendable (SessionEvent) -> Void
    private let lock = NSLock()
    private var sessionID: String?
    private var turnID: String?
    private var selectedModel: String?
    private let coordination: RuntimeCoordination?
    private var streamedMessageIDs: Set<String> = []
    private var approvalMethods: [String: String] = [:]
    private var questionIDs: [String: [String: String]] = [:]
    private var cancellationRequested = false
    private var loadingHistory = false

    public func stop() { rpc.stop() }

    public init(provider: Provider, workingDirectory: String, profileDirectory: String?, accountConfiguration: AccountLaunchConfiguration? = nil, coordination: RuntimeCoordination? = nil, model: String? = nil,
                eventHandler: @escaping @Sendable (SessionEvent) -> Void) throws {
        guard provider.supportedInMVP else {
            throw ShastraError.unsupported("\(provider.title) adapter is planned but not available in this build")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ShastraError.invalidResponse("The workspace folder is unavailable: \(workingDirectory)")
        }
        guard let executable = ExecutableLocator.locate(provider.executable) else {
            throw ShastraError.missingExecutable("\(provider.executable) is not installed")
        }
        self.provider = provider
        self.workingDirectory = workingDirectory
        self.eventHandler = eventHandler
        self.coordination = coordination
        self.selectedModel = model
        var environment: [String: String] = [:]
        if let profileDirectory, !profileDirectory.isEmpty {
            switch provider {
            case .codex: environment["CODEX_HOME"] = profileDirectory
            case .cursor: environment["CURSOR_CONFIG_DIR"] = profileDirectory
            case .grok: environment["GROK_HOME"] = profileDirectory
            case .claude: environment["CLAUDE_CONFIG_DIR"] = profileDirectory
            default: break
            }
        }
        if let accountConfiguration {
            guard accountConfiguration.provider == provider else { throw AccountError("Choose an account for this agent.") }
            environment = accountConfiguration.environment
        }
        if let coordination {
            environment["SHASTRA_AGENT_TOKEN"] = coordination.token
            environment["SHASTRA_SOCKET"] = coordination.socketPath
        }
        if provider == .claude { environment["SHASTRA_CLAUDE_EXECUTABLE"] = executable }
        guard provider != .claude || ClaudeRuntime.isAvailable else { throw ShastraError.missingExecutable("Claude's bridge needs Node.js and its bundled SDK. Rebuild Shastra with the bridge installed.") }
        rpc = try JSONRPCProcess(executable: provider == .claude ? ExecutableLocator.locate("node")! : executable,
                                 arguments: provider == .claude ? [ClaudeRuntime.directory.appending(path: "bridge.mjs").path] : provider == .codex ? ["app-server"] + (coordination?.codexArguments ?? []) : provider == .grok ? ["agent", "stdio"] : ["acp"],
                                 workingDirectory: workingDirectory, environment: environment,
                                 removedEnvironmentKeys: accountConfiguration?.removedEnvironmentKeys ?? [])
        rpc.setHandler { [weak self] message in self?.receive(message) }
    }

    public func connect(existingSessionID: String? = nil, ephemeral: Bool = false) async throws -> String {
        let result: [String: Any]
        if provider == .codex {
            _ = try await rpc.request("initialize", params: [
                "clientInfo": ["name": "shastra", "title": "Shastra", "version": "0.1.0"]])
            rpc.notify("initialized")
            if existingSessionID == nil, let models = try? await rpc.request("model/list").value["data"] as? [[String: Any]] {
                let preferred = models.first { ($0["isDefault"] as? Bool) == true } ?? models.first
                let model = (preferred?["model"] as? String) ?? (preferred?["id"] as? String)
                lock.withLock { if selectedModel == nil { selectedModel = model } }
            }
            if let existingSessionID {
                var params: [String: Any] = ["threadId": existingSessionID, "cwd": workingDirectory]
                if let model = lock.withLock({ selectedModel }) { params["model"] = model }
                if let coordination { params["config"] = coordination.codexConfiguration }
                result = try await rpc.request("thread/resume", params: params).value
            } else {
                var params: [String: Any] = ["cwd": workingDirectory, "ephemeral": ephemeral]
                if let model = lock.withLock({ selectedModel }) { params["model"] = model }
                if let coordination { params["config"] = coordination.codexConfiguration }
                result = try await rpc.request("thread/start", params: params).value
            }
            guard let id = (result["thread"] as? [String: Any])?["id"] as? String else {
                throw ShastraError.invalidResponse("Codex did not return a thread ID")
            }
            guard existingSessionID == nil || existingSessionID == id else {
                throw ShastraError.invalidResponse("The provider returned a different thread while resuming. No message was sent.")
            }
            lock.withLock { sessionID = id }
            if coordination != nil {
                let inventory = try await rpc.request("mcpServerStatus/list", params: ["threadId": id, "detail": "toolsAndAuthOnly"]).value
                guard let servers = inventory["data"] as? [[String: Any]],
                      let server = servers.first(where: { $0["name"] as? String == "shastra" }),
                      let tools = server["tools"] as? [String: Any], tools["agents_list"] != nil else {
                    throw ShastraError.invalidResponse("Shastra coordination tools did not initialize for this runtime")
                }
            }
            return id
        } else {
            let initialization = try await rpc.request("initialize", params: [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
                "clientInfo": ["name": "shastra", "title": "Shastra", "version": "0.1.0"]]).value
            guard (initialization["protocolVersion"] as? Int) == 1 else {
                throw ShastraError.unsupported("\(provider.title) ACP protocol version is incompatible")
            }
            if provider == .cursor {
                _ = try await rpc.request("authenticate", params: ["methodId": "cursor_login"])
            } else if let preferred = (initialization["_meta"] as? [String: Any])?["defaultAuthMethodId"] as? String {
                _ = try await rpc.request("authenticate", params: ["methodId": preferred])
            }
            if let existingSessionID {
                lock.withLock { loadingHistory = true }
                defer { lock.withLock { loadingHistory = false } }
                result = try await rpc.request("session/load", params: [
                    "sessionId": existingSessionID, "cwd": workingDirectory, "mcpServers": coordination.map { [$0.acpServer] } ?? []]).value
            } else {
                result = try await rpc.request("session/new", params: ["cwd": workingDirectory, "mcpServers": coordination.map { [$0.acpServer] } ?? []]).value
            }
            guard let id = (result["sessionId"] as? String) ?? existingSessionID else {
                throw ShastraError.invalidResponse("\(provider.title) did not return a session ID")
            }
            guard existingSessionID == nil || existingSessionID == id else {
                throw ShastraError.invalidResponse("The provider returned a different thread while resuming. No message was sent.")
            }
            lock.withLock { sessionID = id }
            if let model = lock.withLock({ selectedModel }) {
                _ = try await rpc.request("session/set_model", params: ["sessionId": id, "modelId": model])
            }
            return id
        }
    }

    @discardableResult public func prompt(_ text: String) async throws -> String? {
        let id = lock.withLock { sessionID }
        guard let id else { throw ShastraError.invalidResponse("Session is not connected") }
        lock.withLock { cancellationRequested = false }
        eventHandler(.status(.running, "Running"))
        if provider == .codex {
            var params: [String: Any] = ["threadId": id, "input": [["type": "text", "text": text]]]
            if let model = lock.withLock({ selectedModel }) { params["model"] = model }
            let result = try await rpc.request("turn/start", params: params).value
            lock.withLock { turnID = (result["turn"] as? [String: Any])?["id"] as? String }
            if lock.withLock({ cancellationRequested }) { try await cancel() }
            return lock.withLock { turnID }
        } else {
            _ = try await rpc.request("session/prompt", params: [
                "sessionId": id, "prompt": [["type": "text", "text": text]]]).value
            let cancelled = lock.withLock { cancellationRequested }
            eventHandler(.status(cancelled ? .interrupted : .completed,
                                 cancelled ? "Turn stopped" : "Turn completed"))
            return nil
        }
    }

    public func cancel() async throws {
        lock.withLock { cancellationRequested = true }
        let (id, turn) = lock.withLock { (sessionID, turnID) }
        guard let id else { return }
        eventHandler(.status(.running, "Stopping…"))
        if provider == .codex {
            guard let turn else { return } // turn/start will interrupt once the ID arrives.
            _ = try await rpc.request("turn/interrupt", params: ["threadId": id, "turnId": turn])
        } else {
            rpc.notify("session/cancel", params: ["sessionId": id])
        }
    }

    public func answerApproval(id: String, choice: String) throws {
        lock.lock(); let method = approvalMethods.removeValue(forKey: id); lock.unlock()
        guard let method else { throw ShastraError.invalidResponse("Approval request is no longer pending") }
        let identifier: Any = Int(id) ?? id
        if method == "session/request_permission" {
            rpc.respond(id: identifier, result: ["outcome": ["outcome": "selected", "optionId": choice]])
        } else if method == "mcpServer/elicitation/request" {
            guard ["accept", "decline", "cancel"].contains(choice) else { throw ShastraError.invalidResponse("Invalid MCP approval decision") }
            rpc.respond(id: identifier, result: ["action": choice, "content": choice == "accept" ? [:] as [String: String] : NSNull()])
        } else if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
            rpc.respond(id: identifier, result: ["decision": choice])
        } else {
            throw ShastraError.unsupported("Approval response for \(method) is not implemented")
        }
        eventHandler(.status(.running, "Approval answered"))
    }

    public func answerQuestion(id: String, answers: [String: [String]]) throws {
        let method = lock.withLock { approvalMethods.removeValue(forKey: id) }
        if method == "item/tool/requestUserInput" {
            let identifiers = lock.withLock { questionIDs.removeValue(forKey: id) ?? [:] }
            var values: [String: [String: [String]]] = [:]
            for (prompt, value) in answers { if let key = identifiers[prompt] { values[key] = ["answers": value] } }
            rpc.respond(id: Int(id).map { $0 as Any } ?? id, result: ["answers": values])
        } else if method == "shastra/claudeQuestion" { rpc.respond(id: id, result: ["answers": answers]) }
        else { throw ShastraError.invalidResponse("Question is no longer pending") }
        eventHandler(.status(.running, "Question answered"))
    }

    private func receive(_ message: [String: Any]) {
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        if let rawID = message["id"] {
            let id = String(describing: rawID)
            if method == "mcpServer/elicitation/request" {
                let schema = params["requestedSchema"] as? [String: Any]
                let properties = schema?["properties"] as? [String: Any]
                let simpleApproval = params["mode"] as? String == "form" && properties?.isEmpty == true
                lock.withLock { approvalMethods[id] = method }
                let detail = (params["message"] as? String ?? "MCP permission request") + (simpleApproval ? "" : "\nThis form requires the originating application. Decline or cancel here.")
                eventHandler(.approval(id, detail, simpleApproval ? ["accept", "decline"] : ["decline", "cancel"]))
                return
            }
            if method == "item/tool/requestUserInput" {
                let supplied = params["questions"] as? [[String: Any]] ?? []
                guard !supplied.contains(where: { $0["isSecret"] as? Bool == true }) else {
                    rpc.respondError(id: rawID, code: -32602, message: "Use the provider's sign-in flow for secrets"); return
                }
                var identifiers: [String: String] = [:]
                let questions = supplied.compactMap { item -> AgentQuestion? in
                    guard let prompt = item["question"] as? String, let key = item["id"] as? String else { return nil }
                    identifiers[prompt] = key
                    let options = item["options"] as? [[String: Any]] ?? []
                    return AgentQuestion(prompt: prompt, header: item["header"] as? String ?? "Question",
                        options: options.compactMap { $0["label"] as? String }, multiSelect: false)
                }
                lock.withLock { approvalMethods[id] = method; questionIDs[id] = identifiers }
                eventHandler(.question(id, questions)); return
            }
            if method == "shastra/claudeQuestion", let input = params["input"] as? [String: Any] {
                let questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { item -> AgentQuestion? in
                    guard let prompt = item["question"] as? String else { return nil }
                    let options = item["options"] as? [[String: Any]] ?? []
                    let descriptions = options.reduce(into: [String: String]()) { result, option in
                        if let label = option["label"] as? String, let detail = option["description"] as? String { result[label] = detail }
                    }
                    return AgentQuestion(prompt: prompt, header: item["header"] as? String ?? "Question",
                        options: options.compactMap { $0["label"] as? String },
                        multiSelect: item["multiSelect"] as? Bool ?? false, optionDescriptions: descriptions)
                }
                lock.withLock { approvalMethods[id] = method }
                eventHandler(.question(id, questions))
                return
            }
            if method == "session/request_permission" || method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
                lock.lock(); approvalMethods[id] = method; lock.unlock()
                let options: [String]
                if method == "session/request_permission" {
                    let supplied = (params["options"] as? [[String: Any]] ?? [])
                        .compactMap { $0["optionId"] as? String ?? $0["id"] as? String }
                    options = supplied.isEmpty ? ["allow-once", "reject-once"] : supplied
                } else {
                    options = ["accept", "decline"]
                }
                let detail = ((params["toolCall"] as? [String: Any])?["title"] as? String) ?? (params["reason"] as? String) ?? (params["command"] as? String)
                    ?? (try? String(data: JSONSerialization.data(withJSONObject: params, options: .prettyPrinted), encoding: .utf8)) ?? method
                eventHandler(.approval(id, detail, options))
                return
            }
            rpc.respondError(id: rawID, code: -32601, message: "Shastra does not support \(method)")
            eventHandler(.error("This agent requested an unsupported tool: \(method)."))
            return
        }
        switch method {
        case "shastra/messageStart": eventHandler(.messageStart)
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String {
                if let itemID = params["itemId"] as? String { _ = lock.withLock { streamedMessageIDs.insert(itemID) } }
                eventHandler(.text(delta))
            }
        case "turn/completed":
            lock.withLock { turnID = nil; streamedMessageIDs.removeAll() }
            let turn = params["turn"] as? [String: Any] ?? [:]
            let status = turn["status"] as? String ?? "completed"
            let state: ConversationState = status == "completed" ? .completed : status == "failed" ? .failed : .interrupted
            if state == .failed, let error = turn["error"] as? [String: Any], let detail = error["message"] as? String {
                eventHandler(.error(detail))
            } else { eventHandler(.status(state, state == .completed ? "Turn completed" : "Turn stopped")) }
        case "session/update":
            guard !lock.withLock({ loadingHistory }) else { return } // ACP load replays history already displayed by Shastra.
            let update = params["update"] as? [String: Any] ?? [:]
            let type = update["sessionUpdate"] as? String ?? ""
            if type == "agent_message_chunk", let content = update["content"] as? [String: Any],
               let text = content["text"] as? String { eventHandler(.text(text)) }
            else if type.contains("tool") { eventHandler(.tool((update["title"] as? String) ?? type)) }
        case "item/started", "item/completed":
            let item = params["item"] as? [String: Any] ?? [:]
            if item["type"] as? String == "agentMessage" {
                if method == "item/started" { eventHandler(.messageStart) }
                else if let itemID = item["id"] as? String, let text = item["text"] as? String,
                        !lock.withLock({ streamedMessageIDs.contains(itemID) }) {
                    eventHandler(.messageStart)
                    eventHandler(.text(text))
                }
            } else if method == "item/started", let type = item["type"] as? String,
                      ["commandExecution", "fileChange", "mcpToolCall", "customToolCall", "dynamicToolCall", "collabAgentToolCall", "webSearch", "imageView", "imageGeneration"].contains(type) {
                eventHandler(.tool("\(type): \(item["command"] as? String ?? item["status"] as? String ?? "")"))
            }
        case "error":
            let error = params["error"] as? [String: Any] ?? [:]
            eventHandler(.error(error["message"] as? String ?? "Vendor error"))
        case "shastra/processExited":
            eventHandler(.error(params["message"] as? String ?? "Vendor process exited"))
        default: break
        }
    }
}
