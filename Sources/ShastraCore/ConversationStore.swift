import Foundation

public actor ConversationStore {
    public let directory: URL
    private var database: ContinuityDatabase?
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Shastra", directoryHint: .isDirectory)
    }

    private func repository() throws -> ContinuityDatabase {
        if let database { return database }
        let opened = try ContinuityDatabase(directory: directory)
        database = opened
        return opened
    }

    public func load() throws -> [Conversation] { try repository().load() }
    public func save(_ conversations: [Conversation]) throws { try repository().save(conversations) }
    public func search(_ query: String) throws -> [HistorySearchResult] { try repository().search(query) }
    public func export(to url: URL) throws { try repository().export(to: url) }
    public func enqueue(_ delivery: Delivery) throws -> Delivery { try repository().enqueue(delivery) }
    public func transition(_ id: UUID, to state: DeliveryState, receipt: DeliveryReceipt? = nil, detail: String? = nil) throws -> Delivery {
        try repository().transition(id, to: state, receipt: receipt, detail: detail)
    }
    public func recoverDispatches() throws -> [Delivery] { try repository().recoverDispatches() }
    public func unresolvedDeliveries() throws -> [Delivery] { try repository().unresolvedDeliveries() }
    public func contextPrompt(conversation: Conversation, request: String) throws -> String {
        try ContextArchive.prepare(conversation: conversation, request: request, directory: directory.appending(path: "ContextArchives"))
    }

}

public enum ExecutableLocator {
    public static func locate(_ name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + [FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin").path,
               "/opt/homebrew/bin", "/usr/local/bin"]
        for directory in paths {
            let candidate = URL(fileURLWithPath: directory).appending(path: name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        if name == "claude" { return ClaudeRuntime.bundledExecutable }
        return nil
    }
    public static func discover() -> [ProviderAvailability] {
        Provider.allCases.map { ProviderAvailability(provider: $0, path: locate($0.executable)) }
    }
}
