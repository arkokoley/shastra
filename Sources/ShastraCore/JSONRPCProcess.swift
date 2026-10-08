import Foundation

public struct RPCObject: @unchecked Sendable {
    public let value: [String: Any]
}

public final class JSONRPCProcess: @unchecked Sendable {
    public typealias MessageHandler = @Sendable ([String: Any]) -> Void
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<RPCObject, Error>] = [:]
    private var handler: MessageHandler?
    private var stderrText = ""
    private var finished = false

    public init(executable: String, arguments: [String], workingDirectory: String, environment: [String: String] = [:], removedEnvironmentKeys: Set<String> = []) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        var inheritedEnvironment = ProcessInfo.processInfo.environment
        for key in removedEnvironmentKeys { inheritedEnvironment.removeValue(forKey: key) }
        process.environment = inheritedEnvironment.merging(environment) { _, new in new }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { self?.finish(); return }
            self?.consume(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.recordError(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self] _ in self?.finish() }
    }

    deinit {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    public func setHandler(_ handler: @escaping MessageHandler) {
        lock.lock(); self.handler = handler; lock.unlock()
    }

    public func request(_ method: String, params: [String: Any] = [:]) async throws -> RPCObject {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            let id = nextID; nextID += 1
            pending[id] = continuation
            let sent = writeLocked(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            if !sent, let pending = pending.removeValue(forKey: id) {
                pending.resume(throwing: ShastraError.processExited("Could not send \(method) to vendor process"))
            }
            lock.unlock()
        }
    }

    public func notify(_ method: String, params: [String: Any] = [:]) {
        lock.lock(); _ = writeLocked(["jsonrpc": "2.0", "method": method, "params": params]); lock.unlock()
    }

    public func respond(id: Any, result: [String: Any]) {
        lock.lock(); _ = writeLocked(["jsonrpc": "2.0", "id": id, "result": result]); lock.unlock()
    }

    public func respondError(id: Any, code: Int, message: String) {
        lock.lock()
        _ = writeLocked(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
        lock.unlock()
    }

    public func stop() { if process.isRunning { process.terminate() } }

    private func writeLocked(_ object: [String: Any]) -> Bool {
        guard !finished, process.isRunning, JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              var line = String(data: data, encoding: .utf8)?.data(using: .utf8) else { return false }
        line.append(0x0A)
        do { try input.fileHandleForWriting.write(contentsOf: line); return true }
        catch { return false }
    }

    private func consume(_ data: Data) {
        var lines: [Data] = []
        lock.lock()
        var remaining = data[...]
        var oversized = false
        while let newline = remaining.firstIndex(of: 0x0A) {
            buffer.append(contentsOf: remaining[..<newline])
            if buffer.count > 8_388_608 { oversized = true; break }
            lines.append(buffer)
            buffer = Data()
            remaining = remaining[remaining.index(after: newline)...]
        }
        if !oversized {
            buffer.append(contentsOf: remaining)
            oversized = buffer.count > 8_388_608
        }
        if oversized {
            buffer.removeAll()
            lock.unlock()
            finish(detail: "Vendor sent an oversized protocol line")
            stop()
            return
        }
        lock.unlock()
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = object["id"] as? Int, object["method"] == nil {
                lock.lock(); let continuation = pending.removeValue(forKey: id); lock.unlock()
                if let error = object["error"] as? [String: Any] {
                    continuation?.resume(throwing: ShastraError.invalidResponse(error["message"] as? String ?? "Vendor error"))
                } else {
                    continuation?.resume(returning: RPCObject(value: object["result"] as? [String: Any] ?? [:]))
                }
            } else {
                lock.lock(); let current = handler; lock.unlock()
                current?(object)
            }
        }
    }

    private func recordError(_ text: String) {
        lock.lock(); stderrText = String((stderrText + text).suffix(2000)); lock.unlock()
    }

    private func finish(detail failure: String? = nil) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let outstanding = pending; pending.removeAll()
        let detail = failure ?? (stderrText.isEmpty ? "Vendor process exited" : stderrText)
        let current = handler
        lock.unlock()
        for continuation in outstanding.values {
            continuation.resume(throwing: ShastraError.processExited(detail))
        }
        current?(["method": "shastra/processExited", "params": ["message": detail]])
    }
}
