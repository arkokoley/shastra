import Foundation

public actor AgentServiceClient {
    public init() {}
    public func request(_ method: String, params: [String: String] = [:], operationID: String = UUID().uuidString) async throws -> String {
        try await Task.detached {
            let token = try String(contentsOf: ServicePaths.adminToken, encoding: .utf8)
            return try LocalSocket.call(.init(method: method, params: params, token: token, id: operationID)).value ?? ""
        }.value
    }
    public func snapshot() async throws -> AgentServiceSnapshot {
        let value = try await request("snapshot")
        return try JSONDecoder().decode(AgentServiceSnapshot.self, from: Data(value.utf8))
    }
    public func ensureRunning() async throws {
        if (try? await request("health")) == "ready" { return }
        guard let executable = ServicePaths.executable("ShastraService") else { throw ShastraError.missingExecutable("ShastraService is missing from the app bundle") }
        try FileManager.default.createDirectory(at: ServicePaths.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let log = ServicePaths.directory.appending(path: "service.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: log); try handle.seekToEnd()
        defer { try? handle.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
        process.standardInput = FileHandle.nullDevice; process.standardOutput = handle; process.standardError = handle
        // No pipe or UI lifecycle ownership: the helper continues after the app quits.
        try process.run()
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            if (try? await request("health")) == "ready" { return }
        }
        throw ShastraError.processExited("The background service did not become ready. See service.log in Application Support/Shastra.")
    }
}
