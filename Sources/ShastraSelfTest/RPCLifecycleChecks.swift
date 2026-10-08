import Foundation
import ShastraCore

func verifyRPCLifecycle() async throws {
    let rpc = try JSONRPCProcess(executable: "/usr/bin/python3", arguments: ["-u", "-c", "import sys;sys.stdin.readline();sys.stdout.write('x'*9000000);sys.stdout.flush();sys.stdin.read()"],
                                workingDirectory: FileManager.default.temporaryDirectory.path)
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(5))
        if !Task.isCancelled { rpc.stop() }
    }
    defer { watchdog.cancel(); rpc.stop() }
    do {
        _ = try await rpc.request("oversized-response")
        throw ShastraError.invalidResponse("Oversized protocol output was accepted")
    } catch {
        guard error.localizedDescription.contains("oversized protocol line") else { throw error }
    }
    do {
        _ = try await rpc.request("after-exit")
        throw ShastraError.invalidResponse("Request unexpectedly succeeded after protocol failure")
    } catch ShastraError.processExited { }
    print("RPC failure recovery checks passed")
}
