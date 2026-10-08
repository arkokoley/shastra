import Foundation

public struct ChatOrganization: Codable, Equatable, Sendable {
    public var pinned = false
    public var archived = false
    public var unread = false
    public var title: String?
    public init() {}
}
public struct ProjectDefaults: Codable, Equatable, Sendable {
    public var provider: Provider
    public var accountID: UUID?
    public var model: String
    public var background: Bool
    public init(provider: Provider, accountID: UUID?, model: String, background: Bool) {
        self.provider = provider; self.accountID = accountID; self.model = model; self.background = background
    }
}
public struct ExperiencePreferences: Codable, Sendable {
    public var chats: [String: ChatOrganization] = [:]
    public var favoriteWorkspaces: Set<String> = []
    public var projectWorkspaces: [String: String] = [:]
    public var projects: [String: ProjectDefaults] = [:]
    public var modelFavorites: [String: [String]]?
    public var models: [String: [String]] = [:]
    public var attachments: [String: [String]] = [:]
    public var notifications = false
    public init() {}
    public static func read(_ data: Data?) -> Self { data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? .init() }
    public func organization(_ id: UUID) -> ChatOrganization { chats[id.uuidString] ?? .init() }
}

public enum ComposerContext {
    public static func prompt(_ text: String, files: [String]) -> String {
        guard !files.isEmpty else { return text }
        return text + "\n\nAttached local files (read these as context; images are local image files):\n" + files.map { "- " + $0 }.joined(separator: "\n")
    }
    public static func snippet(_ text: String, query: String, length: Int = 180) -> String {
        let text = text.replacingOccurrences(of: "\n", with: " ")
        let word = query.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? query
        let match = text.range(of: word, options: .caseInsensitive)?.lowerBound ?? text.startIndex
        let start = text.index(match, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(start, offsetBy: length, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "…") + text[start..<end] + (end == text.endIndex ? "" : "…")
    }
}
