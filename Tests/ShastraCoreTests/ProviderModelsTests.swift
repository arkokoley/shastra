import Foundation
import Testing
@testable import ShastraCore

@Test func codexCatalogPreservesModelIDsCapabilitiesAndDefault() {
    let rows = ProviderModelReader.parseCodex(["data": [
        ["id": "row-1", "model": "real-wire-model", "displayName": "A friendly model", "isDefault": true, "inputModalities": ["text", "image"], "supportedReasoningEfforts": [["reasoningEffort": "high"]]],
        ["model": "hidden-model", "hidden": true], ["model": "real-wire-model"], ["description": "No ID"]
    ]])
    #expect(rows.count == 1); #expect(rows.first?.id == "real-wire-model")
    #expect(rows.first?.name == "A friendly model"); #expect(rows.first?.isDefault == true)
    #expect(rows.first?.modalities == ["text", "image"]); #expect(rows.first?.reasoningEfforts == ["high"])
}
@Test func cursorAndGrokCatalogsIgnoreNoiseAndKeepVariantIDs() {
    let cursor = "\u{001B}[32mAvailable models\u{001B}[0m\n\nauto - Auto (default)\nmodel-high-fast - Model High Fast\nmodel-high-fast - duplicate\nUse --model to select\n"
    let rows = ProviderModelReader.parseCLI(cursor, provider: .cursor)
    #expect(rows.map(\.id) == ["auto", "model-high-fast"])
    #expect(rows.first?.isDefault == true); #expect(rows.first?.name == "Auto")
    let grok = "You are logged in.\nDefault model: newest\nAvailable models:\n * newest (default)\n - newest-fast\n - custom-model\n"
    #expect(ProviderModelReader.parseCLI(grok, provider: .grok).map(\.id) == ["newest", "newest-fast", "custom-model"])
    #expect(ProviderModelReader.parseCLI("Please login first\n - fake", provider: .grok).isEmpty)
}
@Test func claudeCatalogKeepsAliasesAndCanonicalIDs() {
    let rows = ProviderModelReader.parseClaude(["models": [["value": "sonnet", "resolvedModel": "claude-sonnet-current", "displayName": "Sonnet", "description": "Provider description", "supportedEffortLevels": ["low", "high"]]]])
    #expect(rows.first?.id == "sonnet"); #expect(rows.first?.resolvedID == "claude-sonnet-current")
    #expect(rows.first?.reasoningEfforts == ["low", "high"])
}
@Test func modelCacheNeverCrossesAccountProviderOrWorkspace() async {
    let cache = ModelCatalogCache()
    let first = ModelCatalogContext(provider: .codex, accountID: UUID(), workspace: "/repo")
    let second = ModelCatalogContext(provider: .codex, accountID: UUID(), workspace: "/repo")
    let third = ModelCatalogContext(provider: .codex, accountID: first.accountID, workspace: "/other-repo")
    await cache.store(.init(models: [.init(id: "one", name: "One")], updatedAt: .now, source: "fixture"), for: first)
    #expect(await cache.cached(first)?.models.first?.id == "one")
    #expect(await cache.cached(second) == nil); #expect(await cache.cached(third) == nil)
    #expect(first.preferenceKey != second.preferenceKey)
}
@Test func modelFavoritesMigrateWithoutResettingPreferences() throws {
    var prefs = ExperiencePreferences(); prefs.favoriteWorkspaces = ["/repo"]
    let legacy = try JSONEncoder().encode(prefs)
    #expect(ExperiencePreferences.read(legacy).favoriteWorkspaces == ["/repo"])
    prefs.modelFavorites = ["codex:current": ["favorite"]]
    #expect(ExperiencePreferences.read(try JSONEncoder().encode(prefs)).modelFavorites?["codex:current"] == ["favorite"])
}
@Test func modelDiscoveryRejectsMissingAccountContextBeforeStartingRuntime() async {
    let context = ModelCatalogContext(provider: .cursor, accountID: UUID(), workspace: "/tmp")
    await #expect(throws: (any Error).self) { try await ProviderModelReader.read(context) }
}
