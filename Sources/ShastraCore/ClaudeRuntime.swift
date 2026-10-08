import Foundation
import Darwin

public enum ClaudeRuntime {
    public struct AuthStatus: Sendable {
        public let loggedIn: Bool
        public let email: String?
        public let organization: String?
        public let method: String?
    }
    public static var directory: URL {
        let bundled = Bundle.main.resourceURL?.appending(path: "ClaudeBridge")
        if let bundled, FileManager.default.fileExists(atPath: bundled.appending(path: "bridge.mjs").path) { return bundled }
        let siblingResources = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Resources/ClaudeBridge")
        if FileManager.default.fileExists(atPath: siblingResources.appending(path: "bridge.mjs").path) { return siblingResources }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Bridge/Claude")
    }

    public static var bundledExecutable: String? {
        #if arch(arm64)
        let platform = "darwin-arm64"
        #else
        let platform = "darwin-x64"
        #endif
        let file = directory.appending(path: "node_modules/@anthropic-ai/claude-agent-sdk-\(platform)/claude").path
        return FileManager.default.isExecutableFile(atPath: file) ? file : nil
    }

    public static var isAvailable: Bool {
        ExecutableLocator.locate("node") != nil && FileManager.default.fileExists(atPath: directory.appending(path: "bridge.mjs").path)
            && FileManager.default.fileExists(atPath: directory.appending(path: "node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs").path)
    }

    public static func authentication(configuration: AccountLaunchConfiguration) async throws -> AuthStatus {
        guard let executable = ExecutableLocator.locate("claude") else { throw AccountError("Claude Code is unavailable.") }
        return try await Task.detached(priority: .utility) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["auth", "status", "--json"]
            process.environment = configuration.environment(over: ProcessInfo.processInfo.environment)
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            output.fileHandleForWriting.closeFile()
            let timeout = DispatchWorkItem {
                if process.isRunning { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            defer { timeout.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard data.count <= 65_536, let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AccountError("Could not verify Claude sign-in. Try signing in again.")
            }
            return AuthStatus(loggedIn: status["loggedIn"] as? Bool ?? false, email: status["email"] as? String,
                organization: status["orgId"] as? String, method: status["authMethod"] as? String)
        }.value
    }
}
