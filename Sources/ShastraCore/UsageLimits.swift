import Foundation

public struct UsageWindow: Codable, Sendable, Equatable {
    public let usedPercent: Double
    public let windowDurationMins: Int?
    public let resetsAt: TimeInterval?
    public var remainingPercent: Int { Int(max(0, min(100, 100 - usedPercent))) }
    public var label: String {
        guard let minutes = windowDurationMins else { return "Window" }
        if minutes == 10_080 { return "Weekly" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

public struct UsageBucket: Codable, Sendable, Equatable {
    public let limitId: String?
    public let limitName: String?
    public let planType: String?
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
    public var windows: [UsageWindow] { [primary, secondary].compactMap { $0 } }
}

public struct AccountUsageLimits: Codable, Sendable {
    public let rateLimits: UsageBucket
    public let rateLimitsByLimitId: [String: UsageBucket]?
    public var buckets: [UsageBucket] {
        if let limits = rateLimitsByLimitId, !limits.isEmpty {
            return limits.keys.sorted { a, b in
                if a == "codex" { return b != "codex" }; if b == "codex" { return false }; return a < b
            }.compactMap { limits[$0] }
        }
        return [rateLimits]
    }
}

public enum UsageLimitReader {
    /// Uses the same account/profile environment as the runtime. No thread or model turn is created.
    public static func readCodex(profileDirectory: String? = nil, configuration: AccountLaunchConfiguration? = nil) async throws -> AccountUsageLimits {
        guard let executable = ExecutableLocator.locate("codex") else { throw ShastraError.missingExecutable("Codex is not installed") }
        if let configuration, configuration.provider != .codex { throw AccountError("Usage account does not belong to Codex") }
        var environment: [String: String] = [:]
        if let profileDirectory, !profileDirectory.isEmpty { environment["CODEX_HOME"] = profileDirectory }
        if let configuration { environment = configuration.environment }
        let rpc = try JSONRPCProcess(executable: executable, arguments: ["app-server"],
                                     workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                                     environment: environment, removedEnvironmentKeys: configuration?.removedEnvironmentKeys ?? [])
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(20)); rpc.stop() } catch { }
        }
        defer { timeout.cancel(); rpc.stop() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            _ = try await rpc.request("initialize", params: ["clientInfo": ["name": "shastra_usage", "title": "Shastra usage", "version": "0.3.1"]])
            rpc.notify("initialized")
            let response = try await rpc.request("account/rateLimits/read")
            let data = try JSONSerialization.data(withJSONObject: response.value)
            return try JSONDecoder().decode(AccountUsageLimits.self, from: data)
        } onCancel: { rpc.stop() }
    }
}
