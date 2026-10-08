import Foundation
import ShastraCore

func verifyClaudeBridge() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "shastra-claude-check-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let store = AccountStore(directory: root.appending(path: "accounts"), home: root.appending(path: "home"))
    let token = "synthetic-claude-oauth-secret"
    let data = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": token,
        "email": "claude@example.invalid", "subscriptionType": "max"]])
    let account = try await store.capture(provider: .claude, data: data, label: "Claude fixture")
    let configuration = try await store.configuration(for: account.id, provider: .claude)
    let configRoot = URL(fileURLWithPath: configuration.environment["CLAUDE_CONFIG_DIR"]!)
    precondition(configRoot.path.hasPrefix(root.path))
    let permissions = try fm.attributesOfItem(atPath: configRoot.appending(path: ".credentials.json").path)[.posixPermissions] as! NSNumber
    precondition(permissions.intValue == 0o600)
    let metadata = try String(contentsOf: root.appending(path: "accounts/accounts.json"), encoding: .utf8)
    precondition(!metadata.contains(token))
    let inherited = ["ANTHROPIC_API_KEY": "synthetic", "ANTHROPIC_AUTH_TOKEN": "synthetic",
        "CLAUDE_CODE_OAUTH_TOKEN": "synthetic", "ANTHROPIC_BASE_URL": "https://example.invalid"]
    let environment = configuration.environment(over: inherited)
    precondition(inherited.keys.allSatisfy { environment[$0] == nil })

    guard ClaudeRuntime.isAvailable else { throw AccountError("Install the pinned Claude SDK before running this probe.") }
    let (loginID, freshConfiguration) = try await store.beginLogin(provider: .claude)
    // This invokes only auth status, without initiating a login or model request.
    let status = try await ClaudeRuntime.authentication(configuration: freshConfiguration)
    precondition(!status.loggedIn, "An empty isolated profile inherited another Claude sign-in")
    let session = try AgentSession(provider: .claude, workingDirectory: root.path,
        profileDirectory: nil, accountConfiguration: freshConfiguration) { _ in }
    defer { session.stop() }
    let id = try await session.connect()
    precondition(UUID(uuidString: id) != nil)
    let watchdog = Task { try? await Task.sleep(for: .seconds(20)); if !Task.isCancelled { session.stop() } }
    defer { watchdog.cancel() }
    var authenticationFailed = false
    do {
        try await session.prompt("Reply with exactly READY.")
    } catch {
        let detail = error.localizedDescription.lowercased()
        guard detail.contains("login") || detail.contains("logged in") || detail.contains("authentication") || detail.contains("auth") else { throw error }
        authenticationFailed = true
    }
    guard authenticationFailed else { throw AccountError("An unauthenticated Claude profile unexpectedly completed a turn") }
    session.stop()
    try await store.discardLogin(loginID)
    print("Claude profile isolation, credential permissions, bridge handshake, and real SDK sign-in error passed (no authenticated model turn)")
}

func verifyWorkspaceFileSearch() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "shastra-search-check-\(UUID())")
    defer { try? fm.removeItem(at: root) }
    for path in ["Sources/Readable.swift", "Sources/Other.swift", "node_modules/Readable.swift", ".build/Readable.swift", "dist"] {
        let file = root.appending(path: path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: file)
    }
    try fm.createSymbolicLink(at: root.appending(path: "Readable-link.swift"), withDestinationURL: root.appending(path: "Sources/Readable.swift"))
    let matches = await WorkspaceFileSearch.search(root: root, query: "SOURCES READABLE")
    if matches.map(\.relativePath) != ["Sources/Readable.swift"] { throw AccountError("Search fixture paths: \(matches.map(\.relativePath))") }
    precondition(matches.map(\.relativePath) == ["Sources/Readable.swift"])
    let all = await WorkspaceFileSearch.search(root: root, query: "readable")
    precondition(all.count == 1)
    let namedLikeFolder = await WorkspaceFileSearch.search(root: root, query: "dist")
    precondition(namedLikeFolder.map(\.relativePath) == ["dist"])
    let empty = await WorkspaceFileSearch.search(root: root, query: "  ")
    precondition(empty.isEmpty)
    print("Workspace filename search excludes generated folders and symbolic links and matches path terms")
}
