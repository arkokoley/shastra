import Foundation
import Darwin

public struct ProviderModel: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let isDefault: Bool
    public let modalities: [String]
    public let reasoningEfforts: [String]
    public let resolvedID: String?
    public init(id: String, name: String, detail: String = "", isDefault: Bool = false, modalities: [String] = [], reasoningEfforts: [String] = [], resolvedID: String? = nil) {
        self.id = id; self.name = name; self.detail = detail; self.isDefault = isDefault
        self.modalities = modalities; self.reasoningEfforts = reasoningEfforts; self.resolvedID = resolvedID
    }
}
public struct ModelCatalogContext: Hashable, Sendable {
    public let provider: Provider
    public let accountID: UUID?
    public let profile: String?
    public let workspace: String
    public init(provider: Provider, accountID: UUID? = nil, profile: String? = nil, workspace: String) {
        self.provider = provider; self.accountID = accountID; self.profile = profile; self.workspace = workspace
    }
    public var preferenceKey: String { "\(provider.rawValue):\(accountID?.uuidString ?? profile ?? "current")" }
}
public struct ModelCatalogSnapshot: Sendable {
    public let models: [ProviderModel]
    public let updatedAt: Date
    public let source: String
}
public actor ModelCatalogCache {
    public static let shared = ModelCatalogCache()
    private var snapshots: [ModelCatalogContext: ModelCatalogSnapshot] = [:]
    public func cached(_ context: ModelCatalogContext) -> ModelCatalogSnapshot? { snapshots[context] }
    public func store(_ snapshot: ModelCatalogSnapshot, for context: ModelCatalogContext) { snapshots[context] = snapshot }
}

public enum ProviderModelReader {
    public static func read(_ context: ModelCatalogContext, configuration: AccountLaunchConfiguration? = nil) async throws -> ModelCatalogSnapshot {
        guard context.provider.supportedInMVP else { throw ShastraError.unsupported("Model discovery is unavailable for this runtime.") }
        if let configuration, configuration.provider != context.provider { throw AccountError("The account does not belong to this provider.") }
        guard context.accountID == nil || configuration != nil else { throw AccountError("The selected account must be loaded before discovering models.") }
        var environment: [String: String] = ["NO_COLOR": "1", "TERM": "dumb", "NO_OPEN_BROWSER": "1"]
        if let profile = context.profile, !profile.isEmpty {
            let key = context.provider == .codex ? "CODEX_HOME" : context.provider == .cursor ? "CURSOR_CONFIG_DIR" : context.provider == .grok ? "GROK_HOME" : "CLAUDE_CONFIG_DIR"
            environment[key] = profile
        }
        if let configuration { environment.merge(configuration.environment) { _, new in new } }
        let directory = context.workspace.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : context.workspace
        guard let executable = ExecutableLocator.locate(context.provider.executable) else { throw ShastraError.missingExecutable("Install \(context.provider.executable) to discover its models.") }
        let models: [ProviderModel]
        let source: String
        switch context.provider {
        case .codex, .claude:
            let isCodex = context.provider == .codex
            if !isCodex { environment["SHASTRA_CLAUDE_EXECUTABLE"] = executable }
            guard isCodex || ClaudeRuntime.isAvailable, let runner = isCodex ? executable : ExecutableLocator.locate("node") else { throw ShastraError.missingExecutable("The Claude SDK bridge is unavailable.") }
            let rpc = try JSONRPCProcess(executable: runner, arguments: isCodex ? ["app-server"] : [ClaudeRuntime.directory.appending(path: "bridge.mjs").path], workingDirectory: directory, environment: environment, removedEnvironmentKeys: configuration?.removedEnvironmentKeys ?? [])
            let timeout = Task { do { try await Task.sleep(for: .seconds(25)); rpc.stop() } catch {} }
            defer { timeout.cancel(); rpc.stop() }
            models = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                if isCodex {
                    _ = try await rpc.request("initialize", params: ["clientInfo": ["name": "shastra_models", "version": "0.5.1"]])
                    rpc.notify("initialized")
                    var result: [ProviderModel] = [], cursor: String?, seen = Set<String>()
                    for _ in 0..<50 {
                        try Task.checkCancellation()
                        var params: [String: Any] = ["limit": 100, "includeHidden": false]
                        if let cursor { params["cursor"] = cursor }
                        let response = try await rpc.request("model/list", params: params).value
                        result += parseCodex(response)
                        guard let next = response["nextCursor"] as? String, !next.isEmpty else { return unique(result) }
                        guard seen.insert(next).inserted else { throw ShastraError.invalidResponse("Provider repeated a model catalog page. Refresh to retry.") }
                        cursor = next
                    }
                    throw ShastraError.invalidResponse("Provider model catalog exceeded its page limit.")
                }
                let response = try await rpc.request("shastra/models", params: ["cwd": directory]).value
                return parseClaude(response)
            } onCancel: { rpc.stop() }
            source = isCodex ? "Codex app-server" : "Claude Code SDK"
        case .cursor, .grok:
            let output = try await ModelListCommand.read(executable: executable, directory: directory, environment: environment, removed: configuration?.removedEnvironmentKeys ?? [])
            models = parseCLI(output, provider: context.provider)
            source = "\(context.provider.title) CLI"
        default: throw ShastraError.unsupported("No model discovery adapter")
        }
        try Task.checkCancellation()
        guard !models.isEmpty else { throw ShastraError.invalidResponse("No selectable models were returned. Check this provider’s sign-in and refresh; a custom model ID is still available.") }
        return .init(models: models, updatedAt: .now, source: source)
    }
    public static func parseCodex(_ object: [String: Any]) -> [ProviderModel] {
        unique((object["data"] as? [[String: Any]] ?? []).compactMap { row in
            guard row["hidden"] as? Bool != true, let id = row["model"] as? String ?? row["id"] as? String, !id.isEmpty else { return nil }
            return .init(id: id, name: row["displayName"] as? String ?? id, detail: row["description"] as? String ?? "", isDefault: row["isDefault"] as? Bool ?? false,
                         modalities: row["inputModalities"] as? [String] ?? [], reasoningEfforts: (row["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String })
        })
    }
    public static func parseClaude(_ object: [String: Any]) -> [ProviderModel] {
        unique((object["models"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["value"] as? String, !id.isEmpty else { return nil }
            return .init(id: id, name: row["displayName"] as? String ?? id, detail: row["description"] as? String ?? "", reasoningEfforts: row["supportedEffortLevels"] as? [String] ?? [], resolvedID: row["resolvedModel"] as? String)
        })
    }
    public static func parseCLI(_ text: String, provider: Provider) -> [ProviderModel] {
        let clean = text.replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        var inCatalog = false, result: [ProviderModel] = []
        for raw in clean.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.lowercased().hasPrefix("available models") { inCatalog = true; continue }
            guard inCatalog, !line.isEmpty else { continue }
            var id: String, name: String
            if provider == .cursor {
                guard let divider = line.range(of: " - ") else { continue }
                id = String(line[..<divider.lowerBound]); name = String(line[divider.upperBound...])
            } else {
                guard line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
                let value = String(line.dropFirst(2)); id = String(value.split(separator: " ").first ?? ""); name = value
            }
            guard !id.isEmpty, !id.contains(where: \.isWhitespace), id.count < 200 else { continue }
            let isDefault = name.contains("(default)")
            name = name.replacingOccurrences(of: " (default)", with: "")
            result.append(.init(id: id, name: name, isDefault: isDefault))
        }
        return unique(result)
    }
    private static func unique(_ rows: [ProviderModel]) -> [ProviderModel] {
        var seen = Set<String>(); return rows.filter { seen.insert($0.id).inserted }
    }
}

private final class ModelListCommand: @unchecked Sendable {
    private let process = Process(), output = Pipe(), lock = NSLock()
    private var stopped = false
    private func stop() {
        lock.lock(); stopped = true
        if process.isRunning { process.terminate() }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [self] in
            lock.lock(); defer { lock.unlock() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    private func run(executable: String, directory: String, environment: [String: String], removed: Set<String>) throws -> String {
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = ["models"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env = ProcessInfo.processInfo.environment; for key in removed { env.removeValue(forKey: key) }
        process.environment = env.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        lock.lock()
        do { guard !stopped else { throw CancellationError() }; try process.run(); lock.unlock() }
        catch { lock.unlock(); throw error }
        output.fileHandleForWriting.closeFile()
        let timeout = DispatchWorkItem { [self] in stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
        defer { timeout.cancel(); try? output.fileHandleForReading.close() }
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
            guard data.count + chunk.count <= 1_048_576 else { stop(); throw ShastraError.invalidResponse("Model catalog output exceeded its size limit.") }
            data.append(chunk)
        }
        process.waitUntilExit()
        guard !lock.withLock({ stopped }) else { throw ShastraError.processExited("Model discovery was cancelled or timed out. Refresh to retry.") }
        guard process.terminationStatus == 0 else { throw ShastraError.processExited("Provider model discovery failed. Check its sign-in in Accounts, then refresh.") }
        return String(decoding: data, as: UTF8.self)
    }
    static func read(executable: String, directory: String, environment: [String: String], removed: Set<String>) async throws -> String {
        let command = Self()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try command.run(executable: executable, directory: directory, environment: environment, removed: removed) }.value
        } onCancel: { command.stop() }
    }
}
