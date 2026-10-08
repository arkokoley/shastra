import CryptoKit
import Foundation
import Darwin
import Security
import LocalAuthentication

public struct AgentAccount: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let provider: Provider
    public var label: String
    public let identity: String
    public let email: String?
    public let plan: String?
    public let source: String
    public let createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
}

public struct AccountLaunchConfiguration: Sendable {
    public let provider: Provider
    public let environment: [String: String]
    public let removedEnvironmentKeys: Set<String>
    public let directory: URL

    public func environment(over base: [String: String]) -> [String: String] {
        var result = base
        for key in removedEnvironmentKeys { result.removeValue(forKey: key) }
        return result.merging(environment) { _, managed in managed }
    }
}

public struct AccountImportResult: Sendable {
    public var imported = 0
    public var skipped = 0
    public init() {}
}

/// Credential files use the vendor formats, inside app-owned 0700 directories.
/// Only identity/display metadata is encoded into the account index.
public actor AccountStore {
    public static let providers: [Provider] = [.codex, .cursor, .claude, .grok]
    public let directory: URL
    private let home: URL
    private let fileManager = FileManager.default

    public init(directory: URL? = nil, home: URL? = nil) {
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Shastra/Accounts", directoryHint: .isDirectory)
    }

    public func list() throws -> [AgentAccount] {
        let file = directory.appending(path: "accounts.json")
        guard fileManager.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([AgentAccount].self, from: Self.readPrivateFile(file))
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    @discardableResult
    public func capture(provider: Provider, data: Data, label: String = "", source: String = "Imported") throws -> AgentAccount {
        let details = try AccountCredential.parse(provider: provider, data: data)
        var accounts = try list()
        let existing = accounts.first { $0.provider == provider && $0.identity == details.identity }
        let id = existing?.id ?? UUID()
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = AgentAccount(id: id, provider: provider,
            label: cleanLabel.isEmpty ? (existing?.label ?? details.email ?? "\(provider.title) account") : String(cleanLabel.prefix(100)),
            identity: details.identity, email: details.email, plan: details.plan, source: existing?.source ?? source,
            createdAt: existing?.createdAt ?? .now, updatedAt: .now, lastUsedAt: existing?.lastUsedAt)
        let configuration = try prepare(id: id, provider: provider)
        let authFile = credentialFile(configuration)
        let oldData = fileManager.fileExists(atPath: authFile.path) ? try Self.readPrivateFile(authFile) : nil
        try Self.writePrivateFile(details.data, to: authFile)
        accounts.removeAll { $0.id == id }
        accounts.append(account)
        do { try save(accounts) }
        catch {
            if let oldData { try? Self.writePrivateFile(oldData, to: authFile) }
            else { try? fileManager.removeItem(at: configuration.directory) }
            throw error
        }
        return account
    }

    public func captureCurrent(provider: Provider, label: String = "") throws -> AgentAccount {
        let data: Data
        switch provider {
        case .codex:
            let root = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appending(path: ".codex")
            let file = root.appending(path: "auth.json")
            guard fileManager.fileExists(atPath: file.path) else {
                throw AccountError("No file-based Codex sign-in was found. Use Sign in to add an account, or import an auth file.")
            }
            data = try Self.readPrivateFile(file)
        case .cursor:
            let file = home.appending(path: ".cursor/auth.json")
            if fileManager.fileExists(atPath: file.path),
               let current = try? Self.readPrivateFile(file),
               (try? AccountCredential.parse(provider: provider, data: current)) != nil {
                data = current
            } else {
                var credentials: [String: String] = [:]
                for (field, service) in [("accessToken", "cursor-access-token"), ("refreshToken", "cursor-refresh-token"), ("apiKey", "cursor-api-key")] {
                    if let secret = try Self.keychainSecret(service: service, account: "cursor-user") {
                        credentials[field] = secret
                    }
                }
                if credentials.isEmpty { credentials = try cursorIDEAuth() }
                data = try JSONSerialization.data(withJSONObject: credentials)
            }
        case .grok:
            let root = ProcessInfo.processInfo.environment["GROK_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appending(path: ".grok")
            data = try Self.readPrivateFile(root.appending(path: "auth.json"))
        case .claude:
            let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appending(path: ".claude")
            let file = root.appending(path: ".credentials.json")
            guard fileManager.fileExists(atPath: file.path) else {
                throw AccountError("Claude manages this sign-in in Keychain. Use Sign in to add a separate Claude account to Shastra.")
            }
            data = try Self.readPrivateFile(file)
        default: throw AccountError("Account management for \(provider.title) is not available yet.")
        }
        return try capture(provider: provider, data: data, label: label, source: "Current sign-in")
    }

    public func importFile(_ file: URL, provider: Provider, label: String = "") throws -> AgentAccount {
        try capture(provider: provider, data: Self.readPrivateFile(file), label: label, source: "Auth file")
    }

    public func rename(_ id: UUID, label: String) throws {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw AccountError("Enter an account name.") }
        var accounts = try list()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { throw AccountError("Account was not found.") }
        accounts[index].label = String(clean.prefix(100))
        accounts[index].updatedAt = .now
        try save(accounts)
    }

    public func remove(_ id: UUID) throws {
        var accounts = try list()
        guard accounts.contains(where: { $0.id == id }) else { return }
        accounts.removeAll { $0.id == id }
        try save(accounts)
        try fileManager.removeItem(at: accountDirectory(id))
    }

    public func configuration(for id: UUID, provider: Provider) async throws -> AccountLaunchConfiguration {
        guard let account = try list().first(where: { $0.id == id }), account.provider == provider else {
            throw AccountError("The selected account is unavailable. Choose another account before sending.")
        }
        let configuration = try prepare(id: id, provider: provider)
        if provider == .claude, !fileManager.fileExists(atPath: credentialFile(configuration).path) {
            let status = try await ClaudeRuntime.authentication(configuration: configuration)
            guard status.loggedIn else { throw AccountError("The selected Claude account needs sign-in. Add it again in Accounts.") }
            return configuration
        }
        _ = try AccountCredential.parse(provider: provider, data: Self.readPrivateFile(credentialFile(configuration)))
        return configuration
    }

    public func markUsed(_ id: UUID) throws {
        var accounts = try list()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].lastUsedAt = .now
        try save(accounts)
    }

    public func beginLogin(provider: Provider) throws -> (UUID, AccountLaunchConfiguration) {
        guard Self.providers.contains(provider) else { throw AccountError("Sign-in for this provider is unavailable.") }
        let id = UUID()
        return (id, try prepare(id: id, provider: provider))
    }

    public func finishLogin(_ id: UUID, configuration: AccountLaunchConfiguration, label: String) async throws -> AgentAccount {
        guard configuration.directory == accountDirectory(id) else { throw AccountError("Invalid sign-in session.") }
        if configuration.provider == .claude {
            let status = try await ClaudeRuntime.authentication(configuration: configuration)
            guard status.loggedIn else { throw AccountError("Claude sign-in did not finish. Try again.") }
            let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
            // Keep this directory: Claude selected its own directory-specific Keychain entry.
            let account = AgentAccount(id: id, provider: .claude, label: name.isEmpty ? status.email ?? "Claude account" : String(name.prefix(100)),
                identity: "oauth:\(status.email ?? id.uuidString):\(status.organization ?? "")", email: status.email,
                plan: nil, source: "Browser sign-in", createdAt: .now, updatedAt: .now)
            var accounts = try list(); accounts.append(account); try save(accounts)
            return account
        }
        let data = try Self.readPrivateFile(credentialFile(configuration))
        let account = try capture(provider: configuration.provider, data: data, label: label, source: "Browser sign-in")
        try discardLogin(id)
        return account
    }

    public func discardLogin(_ id: UUID) throws {
        guard !(try list()).contains(where: { $0.id == id }) else { return }
        let folder = accountDirectory(id)
        if fileManager.fileExists(atPath: folder.path) { try fileManager.removeItem(at: folder) }
    }

    /// Read known account managers in place. No installer or third-party binary is run.
    public func importSavedAccounts(provider: Provider) throws -> AccountImportResult {
        var result = AccountImportResult()
        if provider == .codex {
            let root = home.appending(path: ".codex/accounts")
            let registry = (try? Self.readPrivateFile(root.appending(path: "registry.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let records = registry?["accounts"] as? [[String: Any]] ?? []
            for file in contents(root) where file.lastPathComponent.hasSuffix(".auth.json") {
                do {
                    let data = try Self.readPrivateFile(file)
                    let details = try AccountCredential.parse(provider: provider, data: data)
                    let alias = records.first { record in
                        (record["email"] as? String)?.lowercased() == details.email?.lowercased() &&
                        (details.accountID == nil || record["chatgpt_account_id"] as? String == details.accountID)
                    }?["alias"] as? String ?? ""
                    _ = try capture(provider: provider, data: data, label: alias, source: "codex-auth")
                    result.imported += 1
                } catch { result.skipped += 1 }
            }
        }
        let profiles = home.appending(path: ".cursor-account-switcher/\(provider.rawValue)/profiles")
        for file in contents(profiles) where file.pathExtension == "json" {
            do {
                let object = try Self.jsonObject(Self.readPrivateFile(file))
                let label = object["label"] as? String ?? ""
                var candidates: [Data] = []
                if provider == .cursor, let keys = object["authKeys"] as? [String: String] {
                    candidates.append(try JSONSerialization.data(withJSONObject: Self.cursorCredentials(keys)))
                }
                if let files = object["authFiles"] as? [String: String] {
                    for key in files.keys.sorted() where ["auth.json", ".credentials.json"].contains(URL(fileURLWithPath: key).lastPathComponent) {
                        if let decoded = Data(base64Encoded: files[key]!) { candidates.append(decoded) }
                    }
                }
                guard let data = candidates.first(where: { (try? AccountCredential.parse(provider: provider, data: $0)) != nil }) else {
                    throw AccountError("This saved profile contains no usable credentials.")
                }
                _ = try capture(provider: provider, data: data, label: label, source: "cursor-account-switcher")
                result.imported += 1
            } catch { result.skipped += 1 }
        }
        if provider == .grok {
            let root = home.appending(path: "Library/Application Support/GrokSwitch/accounts")
            for folder in contents(root) {
                do {
                    let meta = (try? Self.readPrivateFile(folder.appending(path: "meta.json")))
                        .flatMap { try? Self.jsonObject($0) }
                    _ = try capture(provider: provider, data: Self.readPrivateFile(folder.appending(path: "auth.snapshot.json")),
                                    label: meta?["label"] as? String ?? meta?["name"] as? String ?? "", source: "Grok Switch")
                    result.imported += 1
                } catch { result.skipped += 1 }
            }
        }
        return result
    }

    private func prepare(id: UUID, provider: Provider) throws -> AccountLaunchConfiguration {
        let root = accountDirectory(id)
        try Self.makePrivateDirectory(directory)
        try Self.makePrivateDirectory(root)
        let authRoot: URL
        var environment: [String: String]
        var removed: Set<String>
        switch provider {
        case .codex:
            authRoot = root.appending(path: "codex")
            environment = ["CODEX_HOME": authRoot.path]
            removed = ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_AUTH_TOKEN", "OPENAI_BASE_URL"]
            try Self.makePrivateDirectory(authRoot)
            if !fileManager.fileExists(atPath: authRoot.appending(path: "config.toml").path) {
                try Self.writePrivateFile(Data("cli_auth_credentials_store = \"file\"\n".utf8), to: authRoot.appending(path: "config.toml"))
            }
        case .cursor:
            let isolatedHome = root.appending(path: "home")
            try Self.makePrivateDirectory(isolatedHome)
            authRoot = isolatedHome.appending(path: ".cursor")
            environment = ["HOME": isolatedHome.path, "CURSOR_CONFIG_DIR": authRoot.path,
                           "CURSOR_DATA_DIR": authRoot.path, "AGENT_CLI_CREDENTIAL_STORE": "file"]
            removed = ["CURSOR_API_KEY", "CURSOR_API_ENDPOINT", "XDG_CONFIG_HOME", "XDG_DATA_HOME"]
        case .grok:
            authRoot = root.appending(path: "grok")
            environment = ["GROK_HOME": authRoot.path]
            removed = ["GROK_AUTH", "GROK_AUTH_PATH", "GROK_AUTH_PROVIDER_ACCESS_TOKEN", "GROK_AUTH_PROVIDER_REFRESH_TOKEN",
                       "GROK_AUTH_PROVIDER_COMMAND", "GROK_DEPLOYMENT_KEY", "XAI_API_KEY", "GROK_API_KEY"]
        case .claude:
            authRoot = root.appending(path: "claude")
            environment = ["CLAUDE_CONFIG_DIR": authRoot.path]
            removed = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN",
                       "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "CLAUDE_CODE_USE_ANTHROPIC_AWS"]
        default: throw AccountError("This provider does not support saved accounts yet.")
        }
        try Self.makePrivateDirectory(authRoot)
        return AccountLaunchConfiguration(provider: provider, environment: environment, removedEnvironmentKeys: removed, directory: root)
    }

    private func accountDirectory(_ id: UUID) -> URL { directory.appending(path: id.uuidString) }
    private func credentialFile(_ configuration: AccountLaunchConfiguration) -> URL {
        switch configuration.provider {
        case .codex: URL(fileURLWithPath: configuration.environment["CODEX_HOME"]!).appending(path: "auth.json")
        case .cursor: URL(fileURLWithPath: configuration.environment["CURSOR_CONFIG_DIR"]!).appending(path: "auth.json")
        case .grok: URL(fileURLWithPath: configuration.environment["GROK_HOME"]!).appending(path: "auth.json")
        case .claude: URL(fileURLWithPath: configuration.environment["CLAUDE_CONFIG_DIR"]!).appending(path: ".credentials.json")
        default: configuration.directory.appending(path: "auth.json")
        }
    }
    private func save(_ accounts: [AgentAccount]) throws {
        try Self.makePrivateDirectory(directory)
        try Self.writePrivateFile(JSONEncoder().encode(accounts), to: directory.appending(path: "accounts.json"))
    }
    private func contents(_ root: URL) -> [URL] {
        Array(((try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).prefix(512))
    }
    private func cursorIDEAuth() throws -> [String: String] {
        let db = try SQLiteReadOnly(path: home.appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb").path)
        var keys: [String: String] = [:]
        try db.rows("SELECT key, value FROM ItemTable WHERE key IN ('cursorAuth/accessToken', 'cursorAuth/refreshToken', 'cursorAuth/cachedEmail')") { row in
            if let key = SQLiteReadOnly.text(row, 0), let value = SQLiteReadOnly.text(row, 1) { keys[key] = value }
        }
        return Self.cursorCredentials(keys)
    }
    private static func cursorCredentials(_ keys: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, field) in [("cursorAuth/accessToken", "accessToken"), ("cursorAuth/refreshToken", "refreshToken"), ("cursorAuth/cachedEmail", "email")] {
            if let value = keys[key] {
                result[field] = (try? JSONDecoder().decode(String.self, from: Data(value.utf8))) ?? value
            }
        }
        return result
    }
    private static func keychainSecret(service: String, account: String) throws -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, let string = String(data: data, encoding: .utf8) else {
            throw AccountError("Cursor credentials are unavailable in Keychain. Use Sign in to add the account directly to Shastra.")
        }
        return string
    }
    static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AccountError("Choose a valid vendor authentication JSON file.")
        }
        return object
    }
    static func readPrivateFile(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 1_048_576 else {
            throw AccountError("The authentication file is empty, unavailable, or too large.")
        }
        return try Data(contentsOf: url)
    }
    static func makePrivateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw AccountError("Account storage must be a private directory.") }
        } else { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    static func writePrivateFile(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw AccountError("Could not create private account storage.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        // POSIX rename atomically replaces the destination without following a symlink.
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw AccountError("Could not save account credentials.") }
    }
}

public struct AccountError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

private struct AccountCredential {
    let data: Data
    let identity: String
    let accountID: String?
    let email: String?
    let plan: String?

    static func parse(provider: Provider, data: Data) throws -> Self {
        let object = try AccountStore.jsonObject(data)
        let token: String
        var accountID: String?
        var email: String?
        var plan: String?
        var identity: String?
        switch provider {
        case .codex:
            if let apiKey = string(object, "OPENAI_API_KEY") {
                token = apiKey
                identity = "api:\(digest(apiKey))"
            } else if let tokens = object["tokens"] as? [String: Any], let access = string(tokens, "access_token") {
                token = access
                let claims = jwt(string(tokens, "id_token") ?? access)
                let auth = claims?["https://api.openai.com/auth"] as? [String: Any]
                accountID = string(tokens, "account_id") ?? auth.flatMap { string($0, "chatgpt_account_id") }
                email = claims.flatMap { string($0, "email") }
                plan = auth.flatMap { string($0, "chatgpt_plan_type") }
                if let accountID { identity = "oauth:\(claims.flatMap { string($0, "sub") } ?? email ?? ""):\(accountID)" }
            } else { throw AccountError("This file has no usable Codex credentials.") }
        case .cursor:
            guard let value = string(object, "accessToken") ?? string(object, "apiKey") else {
                throw AccountError("No Cursor sign-in was found. Use Sign in, or import a saved Cursor account.")
            }
            token = value
            let claims = jwt(value)
            email = string(object, "email") ?? claims.flatMap { string($0, "email") }
            identity = claims.flatMap { string($0, "sub") }.map { "oauth:\($0)" }
            if identity == nil, let email { identity = "email:\(email.lowercased())" }
        case .grok:
            let entries = findCredentials(object)
            guard entries.count <= 1 else {
                throw AccountError("This Grok file contains multiple sign-ins. Import an individual account snapshot, or use Sign in.")
            }
            let credentials = entries.first
            guard let value = credentials.flatMap({ string($0, "key") ?? string($0, "access_token") ?? string($0, "accessToken") ?? string($0, "token") }),
                  value != "[keychain]" else {
                throw AccountError("No usable Grok credentials were found. Use Sign in to add this account.")
            }
            token = value
            let claims = jwt(value)
            email = credentials.flatMap { string($0, "email") } ?? claims.flatMap { string($0, "email") }
            identity = credentials.flatMap { string($0, "user_id") }.map { "oauth:\($0)" }
                ?? claims.flatMap { string($0, "sub") }.map { "oauth:\($0)" }
            if identity == nil, let email { identity = "email:\(email.lowercased())" }
        case .claude:
            guard let oauth = object["claudeAiOauth"] as? [String: Any], let value = string(oauth, "accessToken") else {
                throw AccountError("No Claude OAuth credentials were found in this file.")
            }
            token = value
            email = string(oauth, "email")
            plan = string(oauth, "subscriptionType")
            identity = email.map { "email:\($0.lowercased())" }
        default: throw AccountError("Saved accounts are unavailable for this provider.")
        }
        guard !token.contains("\n"), token.utf8.count <= 100_000 else { throw AccountError("Invalid authentication file.") }
        return Self(data: data, identity: identity ?? "token:\(digest(token))", accountID: accountID, email: email, plan: plan)
    }
    private static func string(_ object: [String: Any], _ key: String) -> String? {
        guard let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    private static func jwt(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? AccountStore.jsonObject(data)
    }
    private static func digest(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func findCredentials(_ object: [String: Any], depth: Int = 0) -> [[String: Any]] {
        guard depth < 6 else { return [] }
        if ["key", "access_token", "accessToken", "token"].contains(where: { string(object, $0) != nil }) { return [object] }
        return object.keys.sorted().flatMap { key in
            (object[key] as? [String: Any]).map { findCredentials($0, depth: depth + 1) } ?? []
        }
    }
}
