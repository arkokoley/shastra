import Foundation
import Darwin
import SwiftTerm

private final class TerminalLifecycleProbe: LocalProcessDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var outputStorage = ""
    private var exitsStorage: [(Int32?)] = []

    var output: String { lock.lock(); defer { lock.unlock() }; return outputStorage }
    var exitCount: Int { lock.lock(); defer { lock.unlock() }; return exitsStorage.count }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        lock.lock(); exitsStorage.append(exitCode); lock.unlock()
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        let chunk = String(decoding: slice, as: UTF8.self)
        lock.lock(); outputStorage += chunk; lock.unlock()
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: 24, ws_col: 80, ws_xpixel: 800, ws_ypixel: 600)
    }
}

/// Run from ShastraSelfTest's main entry point to verify process exit, terminal input,
/// bounded shutdown, and reuse of one LocalProcess instance after termination.
func verifyTerminalLifecycle() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("shastra-terminal-check-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let naturalExitProbe = TerminalLifecycleProbe()
    let naturalExit = LocalProcess(delegate: naturalExitProbe,
                                   dispatchQueue: DispatchQueue(label: "shastra.lifecycle.natural"))
    defer { if naturalExit.running && naturalExit.shellPid > 1 { _ = kill(naturalExit.shellPid, SIGKILL) } }
    naturalExit.startProcess(executable: "/bin/sh", args: ["-c", "exit 7"], currentDirectory: directory.path)
    try await waitForTerminalState("natural exit", timeout: 5) {
        naturalExitProbe.exitCount == 1 && !naturalExit.running
    }

    let inputProbe = TerminalLifecycleProbe()
    let inputProcess = LocalProcess(delegate: inputProbe,
                                    dispatchQueue: DispatchQueue(label: "shastra.lifecycle.input"))
    defer { if inputProcess.running && inputProcess.shellPid > 1 { _ = kill(inputProcess.shellPid, SIGKILL) } }
    inputProcess.startProcess(executable: "/bin/sh",
                              args: ["-c", "IFS= read -r line; printf 'SHASTRA_INPUT:%s\\n' \"$line\""],
                              currentDirectory: directory.path)
    inputProcess.send(data: ArraySlice(Array("terminal-input-check\n".utf8)))
    do {
        try await waitForTerminalState("terminal input", timeout: 5) {
            inputProbe.output.contains("SHASTRA_INPUT:terminal-input-check")
        }
        try await waitForTerminalState("input process exit", timeout: 5) {
            inputProbe.exitCount == 1 && !inputProcess.running
        }
    } catch {
        if inputProcess.running, inputProcess.shellPid > 1 { _ = kill(inputProcess.shellPid, SIGKILL) }
        throw error
    }

    let restartProbe = TerminalLifecycleProbe()
    let restartable = LocalProcess(delegate: restartProbe,
                                   dispatchQueue: DispatchQueue(label: "shastra.lifecycle.restart"))
    defer { if restartable.running && restartable.shellPid > 1 { _ = kill(restartable.shellPid, SIGKILL) } }
    restartable.startProcess(executable: "/bin/sh", args: ["-c", "trap '' HUP; printf SHASTRA_STOP_READY; exec /bin/sleep 30"],
                             currentDirectory: directory.path)
    let firstPID = restartable.shellPid
    guard firstPID > 1, kill(firstPID, 0) == 0 else {
        throw TerminalLifecycleCheckError("SwiftTerm did not expose a valid child process ID")
    }
    try await waitForTerminalState("stop fixture ready", timeout: 5) {
        restartProbe.output.contains("SHASTRA_STOP_READY")
    }
    _ = kill(firstPID, SIGHUP)
    try await Task.sleep(for: .milliseconds(500))
    // An owned shell can ignore HUP; the app escalates only while the same
    // process is still running, so a subsequent launch cannot be killed.
    guard restartable.running, restartable.shellPid == firstPID else {
        throw TerminalLifecycleCheckError("Ignored-HUP fixture exited before the shutdown fallback")
    }
    _ = kill(firstPID, SIGKILL)
    try await waitForTerminalState("bounded stop", timeout: 5) {
        restartProbe.exitCount == 1 && !restartable.running
    }
    restartable.startProcess(executable: "/bin/sh", args: ["-c", "exit 0"],
                             currentDirectory: directory.path)
    try await waitForTerminalState("restart after stop", timeout: 5) {
        restartProbe.exitCount == 2 && !restartable.running
    }

    print("SwiftTerm lifecycle checks passed: natural exit, input, ignored-HUP shutdown fallback, restart")
}

private struct TerminalLifecycleCheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func waitForTerminalState(_ label: String, timeout: TimeInterval,
                                  condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw TerminalLifecycleCheckError("Timed out waiting for \(label)")
}
