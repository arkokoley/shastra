import Foundation
import Darwin

/// Uses the installed vendor CLI's browser flow with an isolated credential store.
/// Authentication output is drained, never copied into a chat, log, or error message.
public final class AccountLogin: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false

    public init() {}

    public func run(configuration: AccountLaunchConfiguration, executable: String? = nil) async throws {
        guard let executable = executable ?? ExecutableLocator.locate(configuration.provider.executable) else {
            throw AccountError("Install \(configuration.provider.title)'s CLI before signing in.")
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = configuration.provider == .claude ? ["auth", "login", "--claudeai"] : configuration.provider == .grok ? ["login", "--oauth"] : ["login"]
        process.currentDirectoryURL = configuration.directory
        process.environment = configuration.environment(over: ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                process.terminationHandler = { [weak self] child in
                    guard let self else { continuation.resume(throwing: CancellationError()); return }
                    self.lock.lock()
                    let cancelled = self.cancelled
                    self.finished = true
                    self.lock.unlock()
                    if cancelled { continuation.resume(throwing: CancellationError()) }
                    else if child.terminationStatus == 0 { continuation.resume() }
                    else { continuation.resume(throwing: AccountError("\(configuration.provider.title) sign-in did not finish (exit \(child.terminationStatus)). Try again.")) }
                }
                do { try process.run(); lock.unlock() }
                catch { finished = true; lock.unlock(); continuation.resume(throwing: AccountError("Could not start \(configuration.provider.title) sign-in.")) }
            }
        } onCancel: { self.cancel() }
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let running = process.isRunning && !finished
        if running { process.terminate() }
        lock.unlock()
        if running {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [self] in
                lock.lock()
                if process.isRunning && !finished { _ = kill(process.processIdentifier, SIGKILL) }
                lock.unlock()
            }
        }
    }

    deinit { if process.isRunning { process.terminate() } }
}
