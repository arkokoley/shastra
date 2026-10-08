import Foundation
import Testing
@testable import ShastraCore

private final class FakeRuntime: ManagedAgentRuntime, @unchecked Sendable {
    let handler: @Sendable (SessionEvent) -> Void
    let lock = NSLock()
    var prompts: [String] = []
    var resumedID: String?
    var rejectResume = false
    private var didStop = false
    init(_ handler: @escaping @Sendable (SessionEvent) -> Void) { self.handler = handler }
    func connect(existingSessionID: String?, ephemeral: Bool) async throws -> String {
        lock.withLock { resumedID = existingSessionID }
        if rejectResume { throw ShastraError.invalidResponse("Fixture: thread unavailable") }
        return existingSessionID ?? "fake-native"
    }
    func prompt(_ text: String) async throws -> String? { lock.withLock { prompts.append(text) }; handler(.status(.running, "Running")); return "fake-turn" }
    func cancel() async throws { handler(.status(.interrupted, "Cancelled")) }
    func stop() { lock.withLock { didStop = true } }
    var stopped: Bool { lock.withLock { didStop } }
    func answerApproval(id: String, choice: String) throws { handler(.status(.running, "Answered")) }
    func answerQuestion(id: String, answers: [String: [String]]) throws {}
    func finish(_ result: String) { handler(.text(result)); handler(.status(.completed, "Completed")) }
    var count: Int { lock.withLock { prompts.count } }
}
private final class RuntimeHarness: @unchecked Sendable {
    let lock = NSLock()
    var runtimes: [UUID: FakeRuntime] = [:]
    var credentials: [UUID: String] = [:]
    func create(_ task: AgentTask, _ config: AccountLaunchConfiguration?, _ coordination: RuntimeCoordination, _ handler: @escaping @Sendable (SessionEvent) -> Void) -> any ManagedAgentRuntime {
        let runtime = FakeRuntime(handler)
        lock.withLock { runtimes[task.id] = runtime; credentials[task.id] = coordination.token }
        return runtime
    }
    func runtime(_ id: UUID) -> FakeRuntime? { lock.withLock { runtimes[id] } }
    func token(_ id: UUID) -> String? { lock.withLock { credentials[id] } }
}
private func serviceFolder() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "shastra-service-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
}
private func eventually(_ predicate: () async throws -> Bool) async throws {
    for _ in 0..<100 { if try await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
    Issue.record("Condition did not become true")
}
private func snapshot(_ service: AgentService, token: String = "admin") async throws -> AgentServiceSnapshot {
    let response = await service.handle(.init(method: "snapshot", token: token))
    return try JSONDecoder().decode(AgentServiceSnapshot.self, from: Data(try #require(response.value).utf8))
}
private func spawn(_ service: AgentService, path: String, key: String = UUID().uuidString, parent: UUID? = nil) async throws -> AgentTask {
    var params = ["workspace": path, "objective": "Test only", "provider": "codex", "isolate": "false"]
    if let parent { params["parentID"] = parent.uuidString }
    let response = await service.handle(.init(method: "agents.spawn", params: params, token: "admin", id: key))
    return try JSONDecoder().decode(AgentTask.self, from: Data(try #require(response.value).utf8))
}

@Test func queuesFollowupsAndSerializesSharedWorkspace() async throws {
    let root = try serviceFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let harness = RuntimeHarness()
    let service = try AgentService(directory: root, cliPath: "/test/cli", adminToken: "admin", runtimeFactory: harness.create)
    let first = try await spawn(service, path: root.path, key: "first")
    try await eventually { harness.runtime(first.id)?.count == 1 }
    let duplicate = try await spawn(service, path: root.path, key: "first")
    #expect(duplicate.id == first.id)
    let second = try await spawn(service, path: root.path)
    #expect(try await snapshot(service).tasks.first { $0.id == second.id }?.status == .queued)
    let send = ServiceRequest(method: "agents.send", params: ["taskID": first.id.uuidString, "message": "Next turn"], token: "admin", id: "followup")
    _ = await service.handle(send); _ = await service.handle(send)
    #expect(try await snapshot(service).tasks.first { $0.id == first.id }?.messages.count == 2)
    #expect(harness.runtime(first.id)?.count == 1)
    harness.runtime(first.id)?.finish("First result")
    try await eventually { harness.runtime(first.id)?.count == 2 }
    harness.runtime(first.id)?.finish("Second result")
    try await eventually { harness.runtime(second.id)?.count == 1 }
    #expect(try await snapshot(service).tasks.first { $0.id == first.id }?.result == "Second result")
}

@Test func scopesCredentialsAndQueuesParentReports() async throws {
    let root = try serviceFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let harness = RuntimeHarness()
    let service = try AgentService(directory: root, cliPath: "/test/cli", adminToken: "admin", runtimeFactory: harness.create)
    let first = try await spawn(service, path: root.path)
    try await eventually { harness.token(first.id) != nil }
    let otherPath = root.appending(path: "other"); try FileManager.default.createDirectory(at: otherPath, withIntermediateDirectories: true)
    let other = try await spawn(service, path: otherPath.path)
    let token = try #require(harness.token(first.id))
    let denied = await service.handle(.init(method: "agents.send", params: ["taskID": other.id.uuidString, "message": "No"], token: token))
    #expect(denied.error != nil)
    #expect(try await snapshot(service, token: token).tasks.map(\.id) == [first.id])
    let approval = await service.handle(.init(method: "approval.answer", params: ["taskID": first.id.uuidString], token: token))
    #expect(approval.error != nil)
    let invalid = await service.handle(.init(method: "snapshot", token: "invalid")); #expect(invalid.error != nil)
    let child = try await spawn(service, path: root.path, parent: first.id)
    harness.runtime(first.id)?.finish("Waiting for child")
    try await eventually { harness.runtime(child.id)?.count == 1 }
    harness.runtime(child.id)?.finish("Child evidence")
    try await eventually { harness.runtime(first.id)?.count == 2 }
    let parent = try #require(try await snapshot(service).tasks.first { $0.id == first.id })
    #expect(parent.messages.last?.sender == child.id)
    #expect(parent.messages.last?.text.contains("Child evidence") == true)
}

@Test func restartNeverReplaysUncertainDispatchAndRevokesCredentials() async throws {
    let root = try serviceFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let db = try ContinuityDatabase(directory: root)
    var state = CoordinationState()
    var task = AgentTask(title: "Interrupted", objective: "Do not duplicate", provider: .codex, workspace: root.path)
    task.status = .running; task.messages[0].state = .dispatching
    state.tasks = [task]; state.grants[StableIdentity.hash("old-token")] = task.id
    try db.saveCoordination(state)
    let harness = RuntimeHarness()
    let service = try AgentService(directory: root, cliPath: "/test/cli", adminToken: "admin", runtimeFactory: harness.create)
    let recovered = try #require(try await snapshot(service).tasks.first)
    #expect(recovered.status == .interrupted); #expect(recovered.messages.first?.state == .unknown)
    #expect(harness.runtime(task.id) == nil)
    let old = await service.handle(.init(method: "snapshot", token: "old-token")); #expect(old.error != nil)
    let send = await service.handle(.init(method: "agents.send", params: ["taskID": task.id.uuidString, "message": "Another"], token: "admin"))
    #expect(send.error != nil)
    _ = await service.handle(.init(method: "delivery.resolve", params: ["taskID": task.id.uuidString, "messageID": task.messages[0].id.uuidString, "accepted": "true", "evidence": "Inspected native transcript"], token: "admin"))
    #expect(harness.runtime(task.id) == nil)
}

@Test func preservesDirtyGitSnapshotAndRefusesIgnoredFileLoss() async throws {
    let root = try serviceFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appending(path: "repo"); try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try LocalCommand.git(repo.path, ["init"])
    try LocalCommand.git(repo.path, ["config", "user.name", "Shastra Test"])
    try LocalCommand.git(repo.path, ["config", "user.email", "test@example.invalid"])
    let file = repo.appending(path: "file.txt")
    try Data("base\n".utf8).write(to: file)
    try LocalCommand.git(repo.path, ["add", "."]); try LocalCommand.git(repo.path, ["commit", "-m", "Fixture"])
    try Data("staged\n".utf8).write(to: file); try LocalCommand.git(repo.path, ["add", "."])
    try Data("unstaged\n".utf8).write(to: file)
    let binary = Data([0, 1, 2, 255]); try binary.write(to: repo.appending(path: "binary.dat"))
    let manager = WorkspaceManager(directory: root.appending(path: "managed"))
    let workspace = try await manager.allocate(from: repo.path)
    #expect(try LocalCommand.git(workspace.path, ["diff", "--cached", "--binary"]) == LocalCommand.git(repo.path, ["diff", "--cached", "--binary"]))
    #expect(try LocalCommand.git(workspace.path, ["diff", "--binary"]) == LocalCommand.git(repo.path, ["diff", "--binary"]))
    #expect(try Data(contentsOf: URL(fileURLWithPath: workspace.path).appending(path: "binary.dat")) == binary)
    let archived = try await manager.archive(workspace.id); #expect(archived.archived)
    let restored = try await manager.restore(workspace.id); #expect(!restored.archived)
    #expect(try LocalCommand.git(restored.path, ["diff", "--cached", "--binary"]) == LocalCommand.git(repo.path, ["diff", "--cached", "--binary"]))
    try Data("ignored.txt\n".utf8).write(to: URL(fileURLWithPath: restored.path).appending(path: ".gitignore"))
    try Data("keep me".utf8).write(to: URL(fileURLWithPath: restored.path).appending(path: "ignored.txt"))
    await #expect(throws: (any Error).self) { try await manager.archive(workspace.id) }
    #expect(FileManager.default.fileExists(atPath: restored.path + "/ignored.txt"))
}

@Test func streamingOrderIsPreservedAndCancellationDoesNotDrainTheQueue() async throws {
    let root = try serviceFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let harness = RuntimeHarness()
    let service = try AgentService(directory: root, cliPath: "/test/cli", adminToken: "admin", runtimeFactory: harness.create)
    let task = try await spawn(service, path: root.path)
    try await eventually { harness.runtime(task.id)?.count == 1 }
    let runtime = try #require(harness.runtime(task.id))
    runtime.handler(.messageStart)
    let expected = (0..<100).map { "\($0)," }.joined()
    for index in 0..<100 { runtime.handler(.text("\(index),")) }
    try await eventually { try await snapshot(service).tasks.first?.entries.last(where: { $0.kind == .assistant })?.text == expected }
    _ = await service.handle(.init(method: "agents.send", params: ["taskID": task.id.uuidString, "message": "Must not run"], token: "admin"))
    _ = await service.handle(.init(method: "agents.cancel", params: ["taskID": task.id.uuidString], token: "admin"))
    try await eventually { try await snapshot(service).tasks.first?.status == .cancelled }
    #expect(runtime.count == 1)
    #expect(try await snapshot(service).tasks.first?.messages.last?.state == .cancelled)
}

@Test func rejectsChangedCreationParametersAndInvalidDependencies() async throws {
    let root = try serviceFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let harness = RuntimeHarness()
    let service = try AgentService(directory: root, cliPath: "/test/cli", adminToken: "admin", runtimeFactory: harness.create)
    _ = try await spawn(service, path: root.path, key: "stable")
    let changed = await service.handle(.init(method: "agents.spawn", params: ["workspace": root.path, "objective": "Test only", "provider": "codex", "isolate": "true"], token: "admin", id: "stable"))
    #expect(changed.error != nil)
    let invalid = await service.handle(.init(method: "agents.spawn", params: ["workspace": root.path, "objective": "Test", "provider": "codex", "isolate": "false", "dependencies": "invalid"], token: "admin"))
    #expect(invalid.error != nil)
    #expect(try await snapshot(service).tasks.count == 1)
}

@Test func dependenciesWaitForBothAcceptanceAndNativeTurnCompletion() async throws {
    let root = try serviceFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let harness = RuntimeHarness()
    let service = try AgentService(directory: root, cliPath: "/test/cli", adminToken: "admin", runtimeFactory: harness.create)
    let parent = try await spawn(service, path: root.path)
    try await eventually { harness.runtime(parent.id)?.count == 1 }
    let childPath = root.appending(path: "child"); try FileManager.default.createDirectory(at: childPath, withIntermediateDirectories: true)
    let response = await service.handle(.init(method: "agents.spawn", params: ["workspace": childPath.path, "objective": "Dependent", "provider": "codex", "isolate": "false", "dependencies": parent.id.uuidString], token: "admin"))
    let child = try JSONDecoder().decode(AgentTask.self, from: Data(try #require(response.value).utf8))
    _ = await service.handle(.init(method: "tasks.complete", params: ["taskID": parent.id.uuidString, "result": "Checks passed"], token: "admin"))
    #expect(harness.runtime(child.id) == nil)
    harness.runtime(parent.id)?.finish("Done")
    try await eventually { harness.runtime(child.id)?.count == 1 }
}

@Test func archivingRetiresIdleRuntimeBeforeRestoringItsWorkspace() async throws {
    let root = try serviceFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let repo = root.appending(path: "repo"); try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try LocalCommand.git(repo.path, ["init"])
    try LocalCommand.git(repo.path, ["config", "user.name", "Shastra Test"])
    try LocalCommand.git(repo.path, ["config", "user.email", "test@example.invalid"])
    try Data("fixture".utf8).write(to: repo.appending(path: "README"))
    try LocalCommand.git(repo.path, ["add", "."]); try LocalCommand.git(repo.path, ["commit", "-m", "Fixture"])
    let harness = RuntimeHarness()
    let service = try AgentService(directory: root, cliPath: "/test/cli", adminToken: "admin", runtimeFactory: harness.create)
    let response = await service.handle(.init(method: "agents.spawn", params: ["workspace": repo.path, "objective": "Test", "provider": "codex", "isolate": "true"], token: "admin"))
    let task = try JSONDecoder().decode(AgentTask.self, from: Data(try #require(response.value).utf8))
    try await eventually { harness.runtime(task.id)?.count == 1 }
    let previous = try #require(harness.runtime(task.id)); previous.finish("Prior context")
    try await eventually { try await snapshot(service).tasks.first?.status == .completed }
    let workspaceID = try #require(task.managedWorkspaceID).uuidString
    let archive = await service.handle(.init(method: "workspaces.archive", params: ["workspaceID": workspaceID], token: "admin"))
    #expect(archive.error == nil); #expect(previous.stopped)
    let blocked = await service.handle(.init(method: "agents.send", params: ["taskID": task.id.uuidString, "message": "Wait for restore"], token: "admin"))
    #expect(blocked.error != nil)
    let restore = await service.handle(.init(method: "workspaces.restore", params: ["workspaceID": workspaceID], token: "admin"))
    #expect(restore.error == nil)
    _ = await service.handle(.init(method: "agents.send", params: ["taskID": task.id.uuidString, "message": "Continue"], token: "admin"))
    try await eventually { harness.runtime(task.id) !== previous && harness.runtime(task.id)?.count == 1 }
    let newRuntime = try #require(harness.runtime(task.id))
    #expect(newRuntime.resumedID == "fake-native")
    #expect(newRuntime.lock.withLock { newRuntime.prompts.first?.contains("Prior context") } == false)
}

@Test func backgroundAdoptionRetainsIdentityAndDoesNotSendOrCopyContext() async throws {
    let root = try serviceFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let harness = RuntimeHarness()
    let service = try AgentService(directory: root, cliPath: "/test/cli", adminToken: "admin", runtimeFactory: harness.create)
    var chat = Conversation(provider: .codex, workingDirectory: root.path)
    chat.sourceIdentity = "codex:original-thread"; chat.vendorSessionID = "original-thread"
    chat.entries = [.init(kind: .user, text: "Old instruction that must not be replayed")]
    chat.migrateEndpoints()
    let payload = String(decoding: try JSONEncoder().encode(chat), as: UTF8.self)
    let request = ServiceRequest(method: "agents.adopt", params: ["conversation": payload], token: "admin", id: "adopt")
    let result = await service.handle(request)
    #expect(result.error == nil)
    _ = await service.handle(request)
    let adopted = try #require(try await snapshot(service).tasks.first)
    #expect(adopted.id == chat.id); #expect(adopted.nativeID == "original-thread")
    #expect(adopted.messages.isEmpty); #expect(harness.runtime(chat.id) == nil)
    #expect(try await snapshot(service).tasks.count == 1)
    _ = await service.handle(.init(method: "agents.send", params: ["taskID": chat.id.uuidString, "message": "New follow-up"], token: "admin"))
    try await eventually { harness.runtime(chat.id)?.count == 1 }
    let runtime = try #require(harness.runtime(chat.id))
    #expect(runtime.resumedID == "original-thread")
    #expect(!runtime.prompts[0].contains("Old instruction"))
    #expect(runtime.prompts[0].contains("New follow-up"))
    runtime.finish("Done")
}

@Test func settledTaskResumesAfterServiceRestartWithoutTranscriptReplay() async throws {
    let root = try serviceFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let db = try ContinuityDatabase(directory: root)
    var state = CoordinationState()
    var task = AgentTask(title: "Prior chat", objective: "Old request", provider: .codex, workspace: root.path)
    task.nativeID = "durable-native-thread"; task.status = .completed
    task.messages[0].state = .accepted; task.entries = [.init(kind: .assistant, text: "Old transcript sentinel")]
    state.tasks = [task]; try db.saveCoordination(state)
    let harness = RuntimeHarness()
    let service = try AgentService(directory: root, cliPath: "/test/cli", adminToken: "admin", runtimeFactory: harness.create)
    _ = await service.handle(.init(method: "agents.send", params: ["taskID": task.id.uuidString, "message": "Resume here"], token: "admin"))
    try await eventually { harness.runtime(task.id)?.count == 1 }
    let runtime = try #require(harness.runtime(task.id))
    #expect(runtime.resumedID == task.nativeID)
    #expect(!runtime.prompts[0].contains("Old transcript sentinel"))
    #expect(try await snapshot(service).tasks.first?.nativeID == task.nativeID)
    runtime.finish("Done")
}

@Test func failedResumeNeverCreatesReplacementOrDispatchesPrompt() async throws {
    let root = try serviceFolder(); defer { try? FileManager.default.removeItem(at: root) }
    let db = try ContinuityDatabase(directory: root)
    var state = CoordinationState()
    var task = AgentTask(title: "Missing chat", objective: "Follow-up", provider: .codex, workspace: root.path)
    task.nativeID = "missing-thread"; state.tasks = [task]; try db.saveCoordination(state)
    let harness = RuntimeHarness()
    let service = try AgentService(directory: root, cliPath: "/test/cli", adminToken: "admin", runtimeFactory: { task, config, coordination, handler in
        let runtime = harness.create(task, config, coordination, handler) as! FakeRuntime
        runtime.rejectResume = true; return runtime
    })
    await service.pump()
    try await eventually { try await snapshot(service).tasks.first?.status == .failed }
    #expect(harness.runtime(task.id)?.resumedID == "missing-thread")
    #expect(harness.runtime(task.id)?.count == 0)
    #expect(try await snapshot(service).tasks.first?.nativeID == "missing-thread")
    #expect(try await snapshot(service).tasks.count == 1)
}
