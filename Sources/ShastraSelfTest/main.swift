import Foundation
import ShastraCore

@main struct ShastraSelfTest {
    static func main() async throws {
        if let index = CommandLine.arguments.firstIndex(of: "--resume-thread"), index + 3 < CommandLine.arguments.count {
            guard let provider = Provider(rawValue: CommandLine.arguments[index + 1]) else { throw ShastraError.invalidResponse("Unknown provider") }
            let nativeID = CommandLine.arguments[index + 2]
            let session = try AgentSession(provider: provider, workingDirectory: CommandLine.arguments[index + 3], profileDirectory: nil) { _ in }
            defer { session.stop() }
            let timeout = Task { try await Task.sleep(for: .seconds(25)); session.stop() }
            defer { timeout.cancel() }
            let resumed = try await session.connect(existingSessionID: nativeID)
            precondition(resumed == nativeID)
            print("Resumed the exact \(provider.title) thread ID. No prompt was sent.")
            return
        }
        if CommandLine.arguments.contains("--usage-limits") {
            let limits = try await UsageLimitReader.readCodex()
            precondition(!limits.buckets.isEmpty)
            for bucket in limits.buckets {
                for window in bucket.windows {
                    print("\(bucket.limitId ?? "codex") \(window.label): \(window.remainingPercent)% remaining; reset available: \(window.resetsAt != nil)")
                }
            }
            print("Read-only account usage probe passed")
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--cursor-observe"), index + 1 < CommandLine.arguments.count {
            try await verifyCursorObservation(nativeID: CommandLine.arguments[index + 1])
            return
        }
        if CommandLine.arguments.contains("--claude-probe") {
            try await verifyClaudeBridge()
            try await verifyWorkspaceFileSearch()
            return
        }
        if CommandLine.arguments.contains("--accounts") {
            try await verifyAccounts()
            return
        }
        if CommandLine.arguments.contains("--workspace-catalog") {
            let chats = try await ConversationStore().load()
            let paths = Array(Set(chats.map(\.workingDirectory)))
            let catalog = WorkspaceIdentityCatalog()
            let resolved = await catalog.resolve(paths)
            let groups = Dictionary(grouping: chats) { resolved[$0.workingDirectory]!.projectID }
            print("Resolved \(paths.count) workspace paths into \(groups.count) projects")
            for (project, chats) in groups where project.hasSuffix("/AuriumOutreach/.git") {
                print("AuriumOutreach grouped chats: \(chats.count)")
            }
            return
        }
        if CommandLine.arguments.contains("--workspace-identity") {
            try await verifyWorkspaceIdentities()
            return
        }
        if CommandLine.arguments.contains("--terminal") {
            try await verifyTerminalLifecycle()
            return
        }
        try verifyHistoryCompatibility()
        try await verifyRPCLifecycle()
        if let index = CommandLine.arguments.firstIndex(of: "--history-id"), index + 1 < CommandLine.arguments.count {
            let id = CommandLine.arguments[index + 1]
            let source = ImportableSession(id: id, title: "Compatibility check", workingDirectory: "/tmp", updatedAt: .now)
            let entries = try await CodexHistory.read(source).entries
            precondition(entries.contains { $0.kind == .user })
            precondition(entries.contains { $0.kind == .assistant })
            print("Previously failing Codex history loaded: \(entries.count) entries")
            return
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "shastra-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationStore(directory: directory)
        var conversation = Conversation(provider: .codex, workingDirectory: "/tmp/work")
        conversation.vendorSessionID = "vendor-session"
        conversation.entries.append(.init(kind: .user, text: "Hello"))
        try await store.save([conversation])
        let loaded = try await store.load()
        precondition(loaded.count == 1)
        precondition(loaded[0].vendorSessionID == "vendor-session")
        precondition(loaded[0].entries[0].text == "Hello")

        let script = """
        import json,sys,time
        for line in sys.stdin:
            request=json.loads(line)
            sys.stdout.write('not json\\n')
            sys.stdout.flush()
            response=json.dumps({'id':request['id'],'result':{'ok':True}})+'\\n'
            sys.stdout.write(response[:8]);sys.stdout.flush()
            time.sleep(0.05)
            sys.stdout.write(response[8:]);sys.stdout.flush()
        """
        let rpc = try JSONRPCProcess(executable: "/usr/bin/python3", arguments: ["-u", "-c", script],
                                     workingDirectory: FileManager.default.temporaryDirectory.path)
        let response = try await rpc.request("probe").value
        precondition(response["ok"] as? Bool == true)
        rpc.stop()
        if ExecutableLocator.locate("codex") != nil {
            let sessions = try await CodexHistory.list(limit: 1)
            if let source = sessions.first {
                let imported = try await CodexHistory.read(source)
                precondition(imported.vendorSessionID == source.id)
            }
        }
        if CommandLine.arguments.contains("--live-codex") {
            let (stream, continuation) = AsyncStream<SessionEvent>.makeStream()
            let session = try AgentSession(provider: .codex, workingDirectory: directory.path,
                                           profileDirectory: nil) { event in continuation.yield(event) }
            _ = try await session.connect(ephemeral: true)
            try await session.prompt("Reply with exactly READY.")
            var reply = ""
            var completed = false
            for await event in stream {
                switch event {
                case .text(let delta): reply += delta
                case .status(let state, _):
                    if state == .completed { completed = true; break }
                    if state == .failed { throw ShastraError.invalidResponse("Live Codex turn failed") }
                case .error(let detail): throw ShastraError.invalidResponse(detail)
                default: break
                }
                if completed { break }
            }
            precondition(reply.trimmingCharacters(in: .whitespacesAndNewlines) == "READY")
            continuation.finish()
        }
        if CommandLine.arguments.contains("--catalog") {
            let catalog = await ConversationCatalog.discover()
            let counts = Dictionary(grouping: catalog, by: \.kind).mapValues(\.count)
            print("Discovered sources: \(counts)")
            for kind in counts.keys.sorted() {
                if let source = catalog.first(where: { $0.kind == kind }) {
                    let entries = try await ConversationCatalog.load(source)
                    print("\(kind) sample messages: \(entries.count)")
                }
            }
            let editorSamples = catalog.filter { $0.kind == "Cursor Editor" }.prefix(30)
            var populated = 0
            for source in editorSamples {
                if !(try await ConversationCatalog.load(source)).isEmpty { populated += 1 }
            }
            print("Cursor Editor populated in first 30: \(populated)")
        }
        if CommandLine.arguments.contains("--grok") {
            let session = try AgentSession(provider: .grok, workingDirectory: directory.path,
                                           profileDirectory: nil) { _ in }
            let id = try await session.connect()
            precondition(!id.isEmpty)
            print("Grok ACP session created")
        }
        if CommandLine.arguments.contains("--live-grok") {
            let (stream, continuation) = AsyncStream<SessionEvent>.makeStream()
            let session = try AgentSession(provider: .grok, workingDirectory: directory.path,
                                           profileDirectory: nil) { event in continuation.yield(event) }
            _ = try await session.connect()
            try await session.prompt("Reply with exactly READY.")
            var reply = ""
            var completed = false
            for await event in stream {
                switch event {
                case .text(let delta): reply += delta
                case .status(let state, _):
                    if state == .completed { completed = true }
                    if state == .failed { throw ShastraError.invalidResponse("Live Grok turn failed") }
                case .error(let detail): throw ShastraError.invalidResponse(detail)
                default: break
                }
                if completed { break }
            }
            precondition(reply.contains("READY"))
            continuation.finish()
        }
        print("Shastra self-tests passed")
    }
}
