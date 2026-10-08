import Foundation
import Testing
@testable import ShastraCore

private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: "shastra-library-tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

@Test func toolTranslationPreservesConfigBacksUpAndUndoes() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let library = RuntimeLibrary()
    let cursor = RuntimeLocation(provider: .cursor, base: root)
    let codex = RuntimeLocation(provider: .codex, base: root)
    let claude = RuntimeLocation(provider: .claude, base: root)
    try write(#"{"mcpServers":{"docs":{"command":"npx","args":["-y","example-server"]}}}"#, to: cursor.config)
    let original = "model = \"test-model\"\n# preserve comment\n"
    try write(original, to: codex.config)
    let item = try #require(try await library.inventory(cursor).first)
    let plan = try await library.preview(item, from: cursor, to: codex, name: "docs copy")
    #expect(!plan.preview.contains("example-server"))
    let receipt = try await library.apply(plan)
    #expect(receipt.backup != nil)
    #expect(try String(contentsOf: codex.config, encoding: .utf8).hasPrefix(original))
    let translated = try #require(try await library.inventory(codex).first)
    #expect(translated.fields?["command"] == .string("npx"))
    try write(#"{"unrelated":null,"mcpServers":{}}"#, to: claude.config)
    let second = try await library.preview(translated, from: codex, to: claude, name: "docs")
    _ = try await library.apply(second)
    let json = try JSONDecoder().decode([String: ConfigValue].self, from: Data(contentsOf: claude.config))
    #expect(json["unrelated"] == .null)
    #expect(try await library.inventory(claude).first?.fields?["type"] == .string("stdio"))
    try await library.undo(receipt)
    #expect(try String(contentsOf: codex.config, encoding: .utf8) == original)
}

@Test func toolCopyRejectsConflictsDriftAndUnapprovedCredentials() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let library = RuntimeLibrary(), source = RuntimeLocation(provider: .cursor, base: root), target = RuntimeLocation(provider: .codex, base: root)
    try write(#"{"mcpServers":{"api":{"url":"https://example.test/mcp","headers":{"Authorization":"fixture-secret"}}}}"#, to: source.config)
    let item = try #require(try await library.inventory(source).first)
    let plan = try await library.preview(item, from: source, to: target, name: "api")
    #expect(plan.containsCredentials); #expect(!plan.preview.contains("fixture-secret"))
    await #expect(throws: (any Error).self) { try await library.apply(plan) }
    let receipt = try await library.apply(plan, includeCredentials: true)
    #expect(try await library.inventory(target).first?.fields?["http_headers"] != nil)
    await #expect(throws: (any Error).self) { try await library.preview(item, from: source, to: target, name: "api") }
    let next = try await library.preview(item, from: source, to: target, name: "another")
    try write("# external edit\n", to: target.config)
    await #expect(throws: (any Error).self) { try await library.apply(next, includeCredentials: true) }
    await #expect(throws: (any Error).self) { try await library.undo(receipt) }
    let fresh = try await library.preview(item, from: source, to: target, name: "another")
    try write(#"{"mcpServers":{}}"#, to: source.config)
    await #expect(throws: (any Error).self) { try await library.apply(fresh, includeCredentials: true) }
}

@Test func skillCopiesBundleAndExecutableModeAndUndo() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let library = RuntimeLibrary(), source = RuntimeLocation(provider: .codex, base: root), target = RuntimeLocation(provider: .claude, base: root, project: true)
    let skill = source.skills.appending(path: "example")
    try write("# Example skill", to: skill.appending(path: "SKILL.md"))
    try write("#!/bin/sh\nexit 0\n", to: skill.appending(path: "scripts/check.sh"))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: skill.appending(path: "scripts/check.sh").path)
    let item = try #require(try await library.inventory(source).first)
    await #expect(throws: (any Error).self) { try await library.preview(item, from: source, to: target, name: "../escape") }
    let plan = try await library.preview(item, from: source, to: target, name: "copied")
    let receipt = try await library.apply(plan)
    #expect(try String(contentsOf: receipt.destination.appending(path: "SKILL.md"), encoding: .utf8) == "# Example skill")
    #expect(try FileManager.default.attributesOfItem(atPath: receipt.destination.appending(path: "scripts/check.sh").path)[.posixPermissions] as? Int == 0o755)
    await #expect(throws: (any Error).self) { try await library.preview(item, from: source, to: target, name: "copied") }
    try await library.undo(receipt)
    #expect(!FileManager.default.fileExists(atPath: receipt.destination.path))
    try FileManager.default.createSymbolicLink(at: skill.appending(path: "linked"), withDestinationURL: root)
    await #expect(throws: (any Error).self) { try await library.preview(item, from: source, to: target, name: "copy-again") }
}

@Test func unsafeOrRuntimeSpecificConfigIsNotSilentlyTranslated() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let library = RuntimeLibrary(), source = RuntimeLocation(provider: .cursor, base: root), target = RuntimeLocation(provider: .grok, base: root)
    for config in [#"{"command":"server","disabled":true}"#, #"{"url":"https://example.test","type":"sse"}"#, #"{"command":"server","env":{"KEY":"${env:KEY}"}}"#, #"{"command":"server","args":null}"#] {
        try write("{\"mcpServers\":{\"example\":\(config)}}", to: source.config)
        let item = try #require(try await library.inventory(source).first)
        await #expect(throws: (any Error).self) { try await library.preview(item, from: source, to: target, name: "example") }
    }
}

@Test func savedCodexAccountKeepsUserConfiguration() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountStore(directory: root.appending(path: "accounts"), home: root)
    let account = try await store.capture(provider: .codex, data: Data(#"{"OPENAI_API_KEY":"fixture-not-real"}"#.utf8))
    let config = root.appending(path: "accounts/\(account.id.uuidString)/codex/config.toml")
    let custom = "cli_auth_credentials_store = \"file\"\n[mcp_servers.example]\ncommand = \"example\"\n"
    try write(custom, to: config)
    _ = try await store.configuration(for: account.id, provider: .codex)
    #expect(try String(contentsOf: config, encoding: .utf8) == custom)
}
