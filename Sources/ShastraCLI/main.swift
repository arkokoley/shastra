import Foundation
import ShastraCore

@main struct ShastraCLI {
    static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "mcp" { try mcp(); return }
        guard let method = CommandLine.arguments.dropFirst().first else {
            print("Usage: shastra <models|health|snapshot|agents.spawn|agents.send|agents.cancel|threads.read|workspaces.list> [key=value ...]\n       shastra mcp (requires a scoped SHASTRA_AGENT_TOKEN)")
            return
        }
        var params = Dictionary(CommandLine.arguments.dropFirst(2).compactMap { item -> (String, String)? in
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init); return pair.count == 2 ? (pair[0], pair[1]) : nil
        }, uniquingKeysWith: { _, last in last })
        if method == "models" {
            guard let name = params["provider"], let provider = Provider(rawValue: name) else {
                throw ShastraError.invalidResponse("Usage: ShastraCLI models provider=codex|cursor|claude|grok [accountID=UUID] [workspace=/path]")
            }
            let accountID = params["accountID"].flatMap(UUID.init(uuidString:))
            guard params["accountID"] == nil || accountID != nil else { throw AccountError("Invalid account ID") }
            let configuration: AccountLaunchConfiguration?
            if let accountID { configuration = try await AccountStore().configuration(for: accountID, provider: provider) }
            else { configuration = nil }
            let context = ModelCatalogContext(provider: provider, accountID: accountID, profile: params["profile"], workspace: params["workspace"] ?? FileManager.default.currentDirectoryPath)
            let catalog = try await ProviderModelReader.read(context, configuration: configuration)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(catalog.models), as: UTF8.self))
            return
        }
        let operationID = params.removeValue(forKey: "operation_id") ?? UUID().uuidString
        let token = try String(contentsOf: ServicePaths.adminToken, encoding: .utf8)
        let response = try LocalSocket.call(.init(method: method, params: params, token: token, id: operationID))
        print(response.value ?? "")
    }

    static func mcp() throws {
        guard let token = ProcessInfo.processInfo.environment["SHASTRA_AGENT_TOKEN"], !token.isEmpty,
              let socket = ProcessInfo.processInfo.environment["SHASTRA_SOCKET"] else {
            throw ShastraError.unsupported("MCP requires a per-runtime credential; admin credentials are never used in MCP mode")
        }
        let names = ["agents_spawn", "agents_list", "agents_send", "agents_wait", "agents_cancel", "threads_read", "tasks_complete", "tasks_blocked"]
        let descriptions = [
            "agents_spawn": "Create a visible Shastra managed-runtime worker. Defaults to an isolated worktree copied from your current workspace. Requires an existing committed Git base. Native desktop creation is not supported.",
            "agents_list": "List your task family with workspaces and state.",
            "agents_send": "Queue a message to an authorized parent, child, or sibling. Delivered after its current turn finishes.",
            "agents_wait": "Read completion status once. If pending, end your turn; child completion is queued to the parent. Do not poll or hold a turn waiting.",
            "agents_cancel": "Request cancellation of a task and remove queued prompts. Runtime acknowledgement determines final status.",
            "threads_read": "Read a bounded page of an authorized task's transcript; use the returned nextCursor for subsequent pages.",
            "tasks_complete": "Publish your result and acceptance/test evidence. Distinguish work completed from remaining limitations.",
            "tasks_blocked": "Publish a concrete blocker requiring attention."
        ]
        let fields: [String: [String]] = [
            "agents_spawn": ["operation_id", "provider", "objective", "title", "acceptance", "isolate", "model", "dependencies"],
            "agents_send": ["operation_id", "taskID", "message"], "agents_list": [],
            "agents_wait": ["taskID"], "agents_cancel": ["taskID"],
            "threads_read": ["taskID", "cursor", "limit"], "tasks_complete": ["result"], "tasks_blocked": ["result"]
        ]
        let required = ["agents_spawn": ["operation_id", "provider", "objective"], "agents_send": ["operation_id", "taskID", "message"], "tasks_complete": ["result"], "tasks_blocked": ["result"]]
        while let line = readLine() {
            guard let data = line.data(using: .utf8), let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard let id = frame["id"] else { continue }
            let params = frame["params"] as? [String: Any] ?? [:]
            var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
            do {
                switch frame["method"] as? String {
                case "initialize":
                    response["result"] = ["protocolVersion": "2024-11-05", "serverInfo": ["name": "shastra", "version": "0.3.0"], "capabilities": ["tools": [:]]]
                case "ping": response["result"] = [:] as [String: String]
                case "resources/list": response["result"] = ["resources": [] as [String]]
                case "resources/templates/list": response["result"] = ["resourceTemplates": [] as [String]]
                case "tools/list":
                    response["result"] = ["tools": names.map { name in
                        ["name": name, "description": descriptions[name]!, "annotations": ["readOnlyHint": ["agents_list", "agents_wait", "threads_read"].contains(name), "destructiveHint": false, "openWorldHint": false], "inputSchema": ["type": "object", "properties": Dictionary(uniqueKeysWithValues: (fields[name] ?? []).map { ($0, ["type": "string"]) }), "required": required[name] ?? [], "additionalProperties": false]] as [String: Any]
                    }]
                case "tools/call":
                    guard let name = params["name"] as? String, names.contains(name) else { throw ShastraError.unsupported("Unknown tool") }
                    let arguments = params["arguments"] as? [String: Any] ?? [:]
                    guard arguments.allSatisfy({ fields[name]!.contains($0.key) && $0.value is String }),
                          (required[name] ?? []).allSatisfy({ arguments[$0] as? String != nil }) else { throw ShastraError.invalidResponse("Invalid tool arguments") }
                    var values = arguments.mapValues { $0 as! String }
                    let operationID = values.removeValue(forKey: "operation_id") ?? UUID().uuidString
                    let method = name.replacingOccurrences(of: "_", with: ".")
                    let result = try LocalSocket.call(.init(method: method, params: values, token: token,
                        id: operationID), path: socket)
                    response["result"] = ["content": [["type": "text", "text": result.value ?? ""]]]
                default: throw ShastraError.unsupported("Method not supported")
                }
            } catch {
                response["result"] = ["isError": true, "content": [["type": "text", "text": error.localizedDescription]]]
            }
            let output = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            FileHandle.standardOutput.write(output + Data([10]))
        }
    }
}
