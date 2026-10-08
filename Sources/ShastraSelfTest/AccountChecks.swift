import Foundation
import ShastraCore

/// Uses only synthetic credentials and an isolated fixture home.
func verifyAccounts() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "shastra-accounts-\(UUID())")
    defer { try? fm.removeItem(at: root) }
    let home = root.appending(path: "vendor-home")
    let directory = root.appending(path: "accounts")
    let store = AccountStore(directory: directory, home: home)
    func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    func write(_ data: Data, _ path: String) throws {
        let file = home.appending(path: path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }
    func codex(_ user: String, token: String = "synthetic-access") throws -> Data {
        let claims = try json(["sub": user, "email": "\(user)@example.invalid",
            "https://api.openai.com/auth": ["chatgpt_account_id": "org-\(user)", "chatgpt_plan_type": "plus"]])
        let payload = claims.base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return try json(["tokens": ["id_token": "e30.\(payload).synthetic", "access_token": token,
            "refresh_token": "synthetic-refresh", "account_id": "org-\(user)"]])
    }
    let workData = try codex("work")
    let work = try await store.capture(provider: .codex, data: workData, label: "Work")
    let personal = try await store.capture(provider: .codex, data: codex("personal"), label: "Personal")
    precondition(work.id != personal.id && work.email == "work@example.invalid" && work.plan == "plus")
    let refreshed = try await store.capture(provider: .codex, data: codex("work", token: "synthetic-refreshed"))
    precondition(refreshed.id == work.id && refreshed.label == "Work")
    let cursor = try await store.capture(provider: .cursor,
        data: json(["accessToken": "synthetic-cursor", "refreshToken": "synthetic-cursor-refresh", "email": "cursor@example.invalid"]))
    let grok = try await store.capture(provider: .grok,
        data: json(["grok": ["key": "synthetic-grok", "user_id": "grok-user", "email": "grok@example.invalid"]]))
    let index = try String(contentsOf: directory.appending(path: "accounts.json"), encoding: .utf8)
    precondition(!index.contains("synthetic-access") && !index.contains("synthetic-refresh") && !index.contains("synthetic-cursor"))
    let mode = try fm.attributesOfItem(atPath: directory.appending(path: "accounts.json").path)[.posixPermissions] as! NSNumber
    precondition(mode.intValue == 0o600)
    let directoryMode = try fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as! NSNumber
    precondition(directoryMode.intValue == 0o700)
    do {
        _ = try await store.configuration(for: work.id, provider: .cursor)
        throw AccountError("Wrong provider accepted")
    } catch let error as AccountError { precondition(error.message.contains("unavailable")) }
    do {
        _ = try await store.capture(provider: .grok, data: json(["grok": ["key": "[keychain]"]]))
        throw AccountError("Unusable keychain placeholder accepted")
    } catch let error as AccountError { precondition(error.message.contains("No usable")) }
    do {
        _ = try await store.capture(provider: .grok, data: json(["first": ["key": "synthetic-first"], "second": ["key": "synthetic-second"]]))
        throw AccountError("Ambiguous account selection accepted")
    } catch let error as AccountError { precondition(error.message.contains("multiple sign-ins")) }

    // Check account-specific files through the same process launcher used by agent sessions.
    let script = """
    import json,os,sys
    for line in sys.stdin:
        request=json.loads(line)
        provider=request['params']['provider']
        home=(os.environ['CODEX_HOME'] if provider=='codex' else os.path.join(os.environ['HOME'],'.cursor') if provider=='cursor' else os.environ['GROK_HOME'])
        with open(os.path.join(home,'auth.json')) as f: auth=json.load(f)
        identity=(auth['tokens']['account_id'] if provider=='codex' else auth['email'] if provider=='cursor' else auth['grok']['user_id'])
        print(json.dumps({'id':request['id'],'result':{'identity':identity,'clean':not any(k in os.environ for k in request['params']['removed'])}}),flush=True)
    """
    for (account, expected) in [(work, "org-work"), (personal, "org-personal"), (cursor, "cursor@example.invalid"), (grok, "grok-user")] {
        let config = try await store.configuration(for: account.id, provider: account.provider)
        let poisoned = Dictionary(uniqueKeysWithValues: config.removedEnvironmentKeys.map { ($0, "synthetic-inherited") })
        let merged = config.environment(over: poisoned)
        precondition(config.removedEnvironmentKeys.allSatisfy { merged[$0] == nil })
        let rpc = try JSONRPCProcess(executable: "/usr/bin/python3", arguments: ["-u", "-c", script],
            workingDirectory: root.path, environment: config.environment, removedEnvironmentKeys: config.removedEnvironmentKeys)
        defer { rpc.stop() }
        let response = try await rpc.request("account", params: ["provider": account.provider.rawValue, "removed": Array(config.removedEnvironmentKeys)]).value
        precondition(response["identity"] as? String == expected && response["clean"] as? Bool == true)
        let authRoot = URL(fileURLWithPath: config.environment[account.provider == .codex ? "CODEX_HOME" : account.provider == .cursor ? "CURSOR_CONFIG_DIR" : "GROK_HOME"]!)
        let permissions = try fm.attributesOfItem(atPath: authRoot.appending(path: "auth.json").path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
    }

    // Import the reference tools' formats without trusting filenames in their metadata.
    try write(workData, ".codex/accounts/arbitrary.auth.json")
    try write(Data("invalid".utf8), ".codex/accounts/broken.auth.json")
    try write(json(["accounts": [["email": "work@example.invalid", "chatgpt_account_id": "org-work", "alias": "Imported Work",
        "account_key": "../../untrusted"]]]), ".codex/accounts/registry.json")
    let importedCodex = try await store.importSavedAccounts(provider: .codex)
    precondition(importedCodex.imported == 1 && importedCodex.skipped == 1)
    try write(json(["label": "Cursor Work", "authKeys": ["cursorAuth/accessToken": "synthetic-cursor",
        "cursorAuth/refreshToken": "synthetic-cursor-refresh", "cursorAuth/cachedEmail": "cursor@example.invalid"]]),
        ".cursor-account-switcher/cursor/profiles/work.json")
    try write(json(["authKeys": ["unrelated": "metadata"], "authFiles": ["/ignored/auth.json":
        try json(["accessToken": "synthetic-cursor", "email": "cursor@example.invalid"]).base64EncodedString()]]),
        ".cursor-account-switcher/cursor/profiles/file.json")
    try write(json(["label": "Codex Personal", "authFiles": ["/untrusted/source/auth.json": try codex("personal").base64EncodedString()]]),
        ".cursor-account-switcher/codex/profiles/personal.json")
    try write(json(["label": "Grok Work"]), "Library/Application Support/GrokSwitch/accounts/work/meta.json")
    try write(json(["grok": ["key": "synthetic-grok", "user_id": "grok-user"]]),
        "Library/Application Support/GrokSwitch/accounts/work/auth.snapshot.json")
    let importedCursor = try await store.importSavedAccounts(provider: .cursor)
    let importedGrok = try await store.importSavedAccounts(provider: .grok)
    let importedAgain = try await store.importSavedAccounts(provider: .codex)
    precondition(importedCursor.imported == 2 && importedGrok.imported == 1 && importedAgain.imported == 2)
    let importedAccounts = try await store.list()
    precondition(importedAccounts.count == 4 && importedAccounts.first { $0.id == work.id }?.label == "Imported Work")
    try await store.rename(work.id, label: "Office")
    try await store.markUsed(work.id)
    let reloaded = try await AccountStore(directory: directory, home: home).list()
    precondition(reloaded.first { $0.id == work.id }?.label == "Office" && reloaded.first { $0.id == work.id }?.lastUsedAt != nil)

    // A selected profile must fail closed after its credentials disappear.
    let personalConfig = try await store.configuration(for: personal.id, provider: .codex)
    try fm.removeItem(at: URL(fileURLWithPath: personalConfig.environment["CODEX_HOME"]!).appending(path: "auth.json"))
    do {
        _ = try await store.configuration(for: personal.id, provider: .codex)
        throw AccountError("Missing saved credentials fell back to a current login")
    } catch is CocoaError { }
    try await store.remove(personal.id)
    let remaining = try await store.list()
    precondition(remaining.count == 3 && !fm.fileExists(atPath: personalConfig.directory.path))

    // Existing persisted chats decode without an account; managed selection survives round trips.
    var chat = Conversation(provider: .codex, workingDirectory: root.path)
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(chat)) as! [String: Any]
    legacy.removeValue(forKey: "accountID")
    let oldChat = try JSONDecoder().decode(Conversation.self, from: json(legacy))
    precondition(oldChat.accountID == nil)
    chat.accountID = work.id
    let decoded = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(chat))
    precondition(decoded.accountID == work.id)

    // Sign-in process success, failure, and cancellation without invoking any real login.
    let executable = root.appending(path: "fake-login")
    func loginScript(_ source: String) throws {
        try Data(("#!/bin/sh\n" + source).utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    try loginScript("printf '%s' '{\"OPENAI_API_KEY\":\"synthetic-browser-key\"}' > \"$CODEX_HOME/auth.json\"\n")
    let (loginID, loginConfig) = try await store.beginLogin(provider: .codex)
    try await AccountLogin().run(configuration: loginConfig, executable: executable.path)
    let signedIn = try await store.finishLogin(loginID, configuration: loginConfig, label: "Browser")
    precondition(signedIn.label == "Browser" && !fm.fileExists(atPath: loginConfig.directory.path))
    try loginScript("echo synthetic-private-output >&2\nexit 7\n")
    let (failedID, failedConfig) = try await store.beginLogin(provider: .cursor)
    do {
        try await AccountLogin().run(configuration: failedConfig, executable: executable.path)
        throw AccountError("Failed sign-in reported success")
    } catch let error as AccountError {
        precondition(error.message.contains("exit 7") && !error.message.contains("synthetic-private-output"))
    }
    try await store.discardLogin(failedID)
    try loginScript("trap '' TERM\nwhile :; do :; done\n")
    let (cancelID, cancelConfig) = try await store.beginLogin(provider: .grok)
    let login = AccountLogin()
    let task = Task { try await login.run(configuration: cancelConfig, executable: executable.path) }
    try await Task.sleep(for: .milliseconds(200))
    let cancelledAt = Date()
    task.cancel()
    do { try await task.value; throw AccountError("Cancelled sign-in reported success") }
    catch is CancellationError { }
    precondition(Date().timeIntervalSince(cancelledAt) < 3)
    try await store.discardLogin(cancelID)
    precondition(!fm.fileExists(atPath: cancelConfig.directory.path))
    print("Account storage, imports, process isolation, compatibility, and sign-in lifecycle checks passed")
}
