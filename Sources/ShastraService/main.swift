import Foundation
import Darwin
import ShastraCore

@main struct ServiceMain {
    static func main() async throws {
        let directory = ServicePaths.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = Darwin.open(directory.appending(path: "service.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
        _ = fcntl(lock, F_SETFD, FD_CLOEXEC)
        defer { Darwin.close(lock) }
        let token: String
        if FileManager.default.fileExists(atPath: ServicePaths.adminToken.path) {
            token = try String(contentsOf: ServicePaths.adminToken, encoding: .utf8)
        } else {
            token = UUID().uuidString + UUID().uuidString
            try Data(token.utf8).write(to: ServicePaths.adminToken, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ServicePaths.adminToken.path)
        guard let cli = ServicePaths.executable("ShastraCLI") else { throw ShastraError.missingExecutable("The Shastra CLI must be packaged beside the service") }
        // The exclusive lock establishes that an old socket is stale.
        unlink(ServicePaths.socket)
        let listener = try LocalSocket.listen(path: ServicePaths.socket)
        defer { Darwin.close(listener); unlink(ServicePaths.socket) }
        let service = try AgentService(directory: directory, cliPath: cli, adminToken: token)
        await service.pump()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while true {
                    let client = Darwin.accept(listener, nil, nil)
                    guard client >= 0 else { continue }
                    Task.detached {
                        defer { Darwin.close(client) }
                        guard LocalSocket.isSameUser(client) else { return }
                        do {
                            let request = try JSONDecoder().decode(ServiceRequest.self, from: LocalSocket.read(client))
                            let response = await service.handle(request)
                            try LocalSocket.write(JSONEncoder().encode(response), to: client)
                            if request.method == "service.shutdown", response.error == nil { Darwin.exit(0) }
                        } catch { /* A disconnected client reconciles by operation ID. */ }
                    }
                }
            }
            await group.waitForAll()
        }
    }
}
